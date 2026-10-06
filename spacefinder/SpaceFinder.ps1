#Requires -Version 5.1
<#
.SYNOPSIS
    SpaceFinder - an interactive console explorer that finds the largest folders.

.DESCRIPTION
    Scans the current directory (or -Path) in the background using a pool of native
    worker threads and shows its subfolders sorted from largest to smallest, with
    proportional data bars. The list updates live while the scan runs.

    Works on Windows PowerShell 5.1 and PowerShell 7+. No external dependencies.

    Keys:
      Up/Down, PgUp/PgDn, Home/End   move the selection (j/k also work)
      Enter, Right                   open the selected folder (l also works)
      Backspace, Left                go to the parent folder (h also works)
      O                              open the selected folder in Explorer
      R                              rescan the current folder
      Q, Esc, Ctrl+C                 quit

.PARAMETER Path
    Folder to analyze. Defaults to the current file system location.

.EXAMPLE
    .\SpaceFinder.ps1
.EXAMPLE
    .\SpaceFinder.ps1 -Path C:\Users
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native scanner (compiled once per PowerShell version and cached in %TEMP%).
# Must stay C# 5 compatible: Windows PowerShell 5.1 compiles with the legacy csc.
# ---------------------------------------------------------------------------
$script:ScannerSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace SpaceFinder1
{
    public sealed class Node
    {
        public string Name;
        public Node Parent;
        public string RootPath;          // non-null only for nodes a scan was started from
        public long Size, Files, Dirs;   // totals for the whole subtree
        public long OwnBytes, OwnFiles;  // files directly inside this folder
        public long OnlineBytes, OnlineFiles;        // online-only (not downloaded) part of the subtree totals
        public long OwnOnlineBytes, OwnOnlineFiles;  // online-only part of OwnBytes/OwnFiles
        public int Pending = 1;          // self + unfinished children
        public bool Done, Denied, IsLink, IsCloud;
        public List<Node> Children;

        public Node(string name, Node parent) { Name = name; Parent = parent; }

        public static Node CreateRoot(string path)
        {
            string trimmed = path.Length > 3 ? path.TrimEnd('\\') : path;
            string name = Path.GetFileName(trimmed);
            Node n = new Node(string.IsNullOrEmpty(name) ? trimmed : name, null);
            n.RootPath = trimmed;
            return n;
        }

        public string FullPath
        {
            get
            {
                List<string> parts = new List<string>();
                Node n = this;
                while (n.RootPath == null && n.Parent != null) { parts.Add(n.Name); n = n.Parent; }
                string p = n.RootPath ?? n.Name;
                for (int i = parts.Count - 1; i >= 0; i--) p = Join(p, parts[i]);
                return p;
            }
        }

        internal static string Join(string a, string b)
        {
            return a.EndsWith("\\") ? a + b : a + "\\" + b;
        }
    }

    // Immutable copy of a node's counters, taken under the lock for the UI thread.
    public sealed class NodeView
    {
        public Node Node;
        public string Name;
        public long Size, Files, Dirs, OwnBytes, OwnFiles;
        public long OnlineBytes, OnlineFiles, OwnOnlineBytes, OwnOnlineFiles;
        public bool Done, Denied, IsLink, IsCloud;
        public int ChildCount;
    }

    public sealed class Scanner
    {
        // Guards every mutation of Node counters, Children, Parent and Pending.
        public static readonly object Sync = new object();

        struct Item
        {
            public Node Node; public string Path;
            public Item(Node n, string p) { Node = n; Path = p; }
        }

        const int FindDataSize = 592;  // sizeof(WIN32_FIND_DATAW)
        static readonly IntPtr InvalidHandle = new IntPtr(-1);

        readonly Stack<Item> work = new Stack<Item>();  // depth-first keeps the queue small
        readonly Node graft;
        readonly Stopwatch clock = new Stopwatch();
        int outstanding, live;
        long dirsScanned, filesScanned;
        volatile bool cancel;

        public readonly Node Root;

        public bool IsRunning { get { return Volatile.Read(ref live) > 0; } }
        public long DirsScanned { get { return Interlocked.Read(ref dirsScanned); } }
        public long FilesScanned { get { return Interlocked.Read(ref filesScanned); } }
        public TimeSpan Elapsed { get { return clock.Elapsed; } }
        public void Cancel() { cancel = true; }

        Scanner(Node root, Node graft) { Root = root; this.graft = graft; }

        // graft: an already scanned (or scanning) node that is a direct child of root.
        // It is attached as-is instead of being scanned again.
        public static Scanner Start(Node root, Node graft)
        {
            Scanner s = new Scanner(root, graft);
            int threads = Math.Max(4, Math.Min(16, Environment.ProcessorCount));
            s.outstanding = 1;
            s.work.Push(new Item(root, ToLongPath(root.RootPath)));
            s.live = threads;
            s.clock.Start();
            for (int i = 0; i < threads; i++)
            {
                Thread t = new Thread(s.Run);
                t.IsBackground = true;
                t.Name = "SpaceFinder scanner";
                t.Start();
            }
            return s;
        }

        static string ToLongPath(string p)
        {
            if (p.StartsWith(@"\\?\")) return p.TrimEnd('\\');
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2).TrimEnd('\\');
            return @"\\?\" + p.TrimEnd('\\');
        }

        void Run()
        {
            IntPtr buf = Marshal.AllocHGlobal(FindDataSize);
            List<Node> kids = new List<Node>();
            List<string> paths = new List<string>();
            try
            {
                while (!cancel)
                {
                    Item item = default(Item);
                    bool got = false;
                    lock (work)
                    {
                        if (work.Count > 0) { item = work.Pop(); got = true; }
                    }
                    if (!got)
                    {
                        if (Volatile.Read(ref outstanding) == 0) break;
                        Thread.Sleep(1);
                        continue;
                    }
                    Process(item, buf, kids, paths);
                    Interlocked.Decrement(ref outstanding);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
                if (Interlocked.Decrement(ref live) == 0) clock.Stop();
            }
        }

        void Process(Item item, IntPtr buf, List<Node> kids, List<string> paths)
        {
            Node node = item.Node;
            kids.Clear();
            paths.Clear();
            long bytes = 0, files = 0, onlineBytes = 0, onlineFiles = 0;
            bool denied = false;
            Node grafted = null;

            try
            {
                // FindExInfoBasic (1), FindExSearchNameMatch (0), FIND_FIRST_EX_LARGE_FETCH (2)
                IntPtr h = FindFirstFileExW(item.Path + "\\*", 1, buf, 0, IntPtr.Zero, 2);
                if (h == InvalidHandle)
                {
                    denied = true;
                }
                else
                {
                    try
                    {
                        do
                        {
                            int attr = Marshal.ReadInt32(buf, 0);
                            if ((attr & 0x10) == 0)  // file: read the size straight from the buffer, no allocations
                            {
                                long size = ((long)(uint)Marshal.ReadInt32(buf, 28) << 32) | (uint)Marshal.ReadInt32(buf, 32);
                                bytes += size;
                                files++;
                                // RECALL_ON_DATA_ACCESS | RECALL_ON_OPEN | OFFLINE: content is not stored locally
                                if ((attr & 0x441000) != 0) { onlineBytes += size; onlineFiles++; }
                                continue;
                            }
                            short c0 = Marshal.ReadInt16(buf, 44);
                            if (c0 == '.')
                            {
                                short c1 = Marshal.ReadInt16(buf, 46);
                                if (c1 == 0 || (c1 == '.' && Marshal.ReadInt16(buf, 48) == 0)) continue;
                            }
                            string name = Marshal.PtrToStringUni(IntPtr.Add(buf, 44));
                            // Junctions/symlinks are not followed. Only name-surrogate reparse tags point
                            // elsewhere; others (e.g. OneDrive/Dropbox cloud folders) are real folders.
                            // dwReserved0 holds the reparse tag when FILE_ATTRIBUTE_REPARSE_POINT is set.
                            int tag = (attr & 0x400) != 0 ? Marshal.ReadInt32(buf, 36) : 0;
                            bool link = (tag & 0x20000000) != 0;
                            bool cloud = (tag & unchecked((int)0xFFFF0FFF)) == unchecked((int)0x9000001A);  // IO_REPARSE_TAG_CLOUD_*
                            if (!link && graft != null && grafted == null && node == Root &&
                                string.Equals(name, graft.Name, StringComparison.OrdinalIgnoreCase))
                            {
                                grafted = graft;
                                continue;
                            }
                            Node child = new Node(name, node);
                            child.IsCloud = cloud;
                            if (link)
                            {
                                child.IsLink = true;
                                child.Done = true;
                                child.Pending = 0;
                                paths.Add(null);
                            }
                            else
                            {
                                paths.Add(Node.Join(item.Path, name));
                            }
                            kids.Add(child);
                        } while (!cancel && FindNextFileW(h, buf));
                    }
                    finally
                    {
                        FindClose(h);
                    }
                }
            }
            catch (Exception)
            {
                denied = true;
            }

            int toScan = 0;
            lock (Sync)
            {
                node.OwnBytes = bytes;
                node.OwnFiles = files;
                node.OwnOnlineBytes = onlineBytes;
                node.OwnOnlineFiles = onlineFiles;
                node.Denied = denied;
                int count = kids.Count + (grafted != null ? 1 : 0);
                if (count > 0)
                {
                    List<Node> list = new List<Node>(count);
                    list.AddRange(kids);
                    if (grafted != null) list.Add(grafted);
                    node.Children = list;
                }
                long addSize = bytes, addFiles = files, addDirs = kids.Count;
                long addOnline = onlineBytes, addOnlineFiles = onlineFiles;
                for (int i = 0; i < kids.Count; i++)
                {
                    if (!kids[i].IsLink) { node.Pending++; toScan++; }
                }
                if (grafted != null)
                {
                    grafted.Parent = node;
                    addSize += grafted.Size;
                    addFiles += grafted.Files;
                    addDirs += grafted.Dirs + 1;
                    addOnline += grafted.OnlineBytes;
                    addOnlineFiles += grafted.OnlineFiles;
                    if (!grafted.Done) node.Pending++;
                }
                for (Node a = node; a != null; a = a.Parent)
                {
                    a.Size += addSize;
                    a.Files += addFiles;
                    a.Dirs += addDirs;
                    a.OnlineBytes += addOnline;
                    a.OnlineFiles += addOnlineFiles;
                }
                Complete(node);
            }

            if (toScan > 0 && !cancel)
            {
                Interlocked.Add(ref outstanding, toScan);
                lock (work)
                {
                    for (int i = kids.Count - 1; i >= 0; i--)
                    {
                        if (paths[i] != null) work.Push(new Item(kids[i], paths[i]));
                    }
                }
            }
            Interlocked.Increment(ref dirsScanned);
            Interlocked.Add(ref filesScanned, files);
        }

        static void Complete(Node n)
        {
            while (n != null)
            {
                if (--n.Pending > 0) return;
                n.Done = true;
                n = n.Parent;
            }
        }

        static NodeView MakeView(Node n)
        {
            NodeView v = new NodeView();
            v.Node = n; v.Name = n.Name;
            v.Size = n.Size; v.Files = n.Files; v.Dirs = n.Dirs;
            v.OwnBytes = n.OwnBytes; v.OwnFiles = n.OwnFiles;
            v.OnlineBytes = n.OnlineBytes; v.OnlineFiles = n.OnlineFiles;
            v.OwnOnlineBytes = n.OwnOnlineBytes; v.OwnOnlineFiles = n.OwnOnlineFiles;
            v.Done = n.Done; v.Denied = n.Denied; v.IsLink = n.IsLink; v.IsCloud = n.IsCloud;
            v.ChildCount = n.Children == null ? 0 : n.Children.Count;
            return v;
        }

        public static NodeView GetView(Node n)
        {
            lock (Sync) { return MakeView(n); }
        }

        // Children sorted by size (largest first), then by name.
        public static NodeView[] GetChildren(Node n)
        {
            NodeView[] arr;
            lock (Sync)
            {
                if (n.Children == null) return new NodeView[0];
                arr = new NodeView[n.Children.Count];
                for (int i = 0; i < arr.Length; i++) arr[i] = MakeView(n.Children[i]);
            }
            Array.Sort(arr, delegate(NodeView a, NodeView b)
            {
                int c = b.Size.CompareTo(a.Size);
                return c != 0 ? c : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
            });
            return arr;
        }

        public static int IndexOf(NodeView[] views, Node n)
        {
            if (n == null || views == null) return -1;
            for (int i = 0; i < views.Length; i++)
            {
                if (object.ReferenceEquals(views[i].Node, n)) return i;
            }
            return -1;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, IntPtr lpFindFileData,
                                              int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool FindNextFileW(IntPtr hFindFile, IntPtr lpFindFileData);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool FindClose(IntPtr hFindFile);
    }

    public static class ConsoleHelper
    {
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint mode);

        // Turns on ENABLE_VIRTUAL_TERMINAL_PROCESSING; returns the previous mode or -1.
        public static long EnableVirtualTerminal()
        {
            IntPtr h = GetStdHandle(-11);
            uint mode;
            if (!GetConsoleMode(h, out mode)) return -1;
            SetConsoleMode(h, mode | 0x4);
            return mode;
        }

        public static void RestoreMode(long mode)
        {
            if (mode >= 0) SetConsoleMode(GetStdHandle(-11), (uint)mode);
        }
    }
}
'@

# Compiled types can't be unloaded, so the namespace includes the source hash: an edited
# script never picks up a stale copy loaded earlier in the same PowerShell session.
function Initialize-Scanner {
    $sha = [Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($script:ScannerSource + $PSVersionTable.PSVersion)
    $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
    $ns = "SpaceFinder_$hash"
    $source = $script:ScannerSource -replace 'namespace SpaceFinder1', "namespace $ns"
    $dll = Join-Path ([IO.Path]::GetTempPath()) "$ns.dll"

    if (-not ("$ns.Scanner" -as [type])) {
        $loaded = $false
        if (Test-Path -LiteralPath $dll) {
            try { Add-Type -Path $dll; $loaded = $true } catch { }
        }
        if (-not $loaded) {
            [Console]::Write('SpaceFinder: preparing scanner...')
            try {
                Add-Type -TypeDefinition $source -OutputAssembly $dll -OutputType Library
                Add-Type -Path $dll
            }
            catch {
                if (-not ("$ns.Scanner" -as [type])) { Add-Type -TypeDefinition $source }
            }
        }
    }
    $script:Scanner = "$ns.Scanner" -as [type]
    $script:NodeType = "$ns.Node" -as [type]
    $script:ConsoleHelper = "$ns.ConsoleHelper" -as [type]
}

# ---------------------------------------------------------------------------
# Rendering helpers (ASCII-only source so Windows PowerShell reads it correctly
# regardless of file encoding; Unicode glyphs are built from code points).
# ---------------------------------------------------------------------------
$script:E = [char]27
$script:FullBlock = [string][char]0x2588
$script:PartialBlocks = @('', [string][char]0x258F, [string][char]0x258E, [string][char]0x258D,
                          [string][char]0x258C, [string][char]0x258B, [string][char]0x258A, [string][char]0x2589)
$script:Ellipsis = [string][char]0x2026
if ($env:WT_SESSION) {
    # Windows Terminal: braille spinner. Legacy console fonts may lack these glyphs.
    $script:Spinner = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) | ForEach-Object { [string][char]$_ }
}
else {
    $script:Spinner = @('|', '/', '-', '\')
}
# Warm colors for the five largest folders, cool for the rest (256-color palette).
$script:TopColors = @(196, 202, 208, 214, 220)
$script:RestColor = 67

function Format-Size([long]$Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $units = 'KB', 'MB', 'GB', 'TB', 'PB'
    $v = [double]$Bytes
    $i = -1
    do { $v /= 1024; $i++ } while ($v -ge 1024 -and $i -lt $units.Length - 1)
    if ($v -ge 100) { return ('{0:0} {1}' -f $v, $units[$i]) }
    if ($v -ge 10) { return ('{0:0.0} {1}' -f $v, $units[$i]) }
    return ('{0:0.00} {1}' -f $v, $units[$i])
}

function Get-Bar([double]$Fraction, [int]$Width) {
    if ($Fraction -le 0) { return ''.PadRight($Width) }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $eighths = [int][Math]::Floor($Fraction * $Width * 8)
    if ($eighths -lt 1) { $eighths = 1 }
    $full = [int][Math]::Floor($eighths / 8)
    ($script:FullBlock * $full + $script:PartialBlocks[$eighths % 8]).PadRight($Width)
}

function Get-Spinner {
    $script:Spinner[[int]([Environment]::TickCount / 100) % $script:Spinner.Length]
}

# Appends one screen row built from (style, text) pairs, clipped to $Max visible chars.
function Add-Row($Sb, [int]$Row, [int]$Max, [object[]]$Segments, [string]$FillStyle) {
    $E = $script:E
    [void]$Sb.Append("$E[$Row;1H")
    $left = $Max
    for ($i = 0; $i -lt $Segments.Length; $i += 2) {
        if ($left -le 0) { break }
        $t = [string]$Segments[$i + 1]
        if ($t.Length -gt $left) { $t = $t.Substring(0, $left) }
        [void]$Sb.Append($Segments[$i]).Append($t)
        $left -= $t.Length
    }
    if ($FillStyle -and $left -gt 0) { [void]$Sb.Append($FillStyle).Append(' ', $left) }
    [void]$Sb.Append("$E[0m$E[K")
}

function Get-ScanStatus($S) {
    $running = $false
    $dirs = 0L
    $elapsed = [TimeSpan]::Zero
    foreach ($sc in $S.Scanners) {
        if ($sc.IsRunning) { $running = $true; $dirs += $sc.DirsScanned }
        if ($sc.Elapsed -gt $elapsed) { $elapsed = $sc.Elapsed }
    }
    [pscustomobject]@{ Running = $running; Dirs = $dirs; Elapsed = $elapsed }
}

function Show-Frame($S, [int]$W, [int]$H) {
    $E = $script:E
    $sb = New-Object System.Text.StringBuilder 16384
    [void]$sb.Append("$E[?25l")
    $max = $W - 1

    if ($W -lt 50 -or $H -lt 8) {
        [void]$sb.Append("$E[H$E[2J")
        Add-Row $sb 1 $max @("$E[33m", 'Window too small - please enlarge it.')
        [Console]::Out.Write($sb.ToString())
        return
    }

    $cur = $script:Scanner::GetView($S.Current)
    $list = $script:Scanner::GetChildren($S.Current)
    $count = $list.Length
    $S.List = $list
    $listH = $H - 5
    $S.ListH = $listH

    # Keep the selection on the same folder even as the order changes during the scan.
    $idx = $script:Scanner::IndexOf($list, $S.SelNode)
    if ($idx -lt 0) {
        $idx = [Math]::Max(0, [Math]::Min($S.SelIndex, $count - 1))
        if ($null -eq $S.SelNode -and $count -gt 0) { $S.SelNode = $list[$idx].Node }
    }
    $S.SelIndex = $idx
    if ($idx -lt $S.Top) { $S.Top = $idx }
    if ($idx -ge $S.Top + $listH) { $S.Top = $idx - $listH + 1 }
    $S.Top = [Math]::Max(0, [Math]::Min($S.Top, $count - $listH))

    $status = Get-ScanStatus $S
    $spin = Get-Spinner

    # Row 1: title + path
    $path = $S.Current.FullPath
    $room = $max - 14
    if ($path.Length -gt $room) { $path = $script:Ellipsis + $path.Substring($path.Length - $room + 1) }
    Add-Row $sb 1 $max @("$E[1;97;48;5;25m", ' SpaceFinder ', "$E[0m", ' ', "$E[1;38;5;117m", $path)

    # Row 2: totals + scan state
    $segs = @("$E[38;5;250m", ' Total ', "$E[1;97m", (Format-Size $cur.Size))
    $hasCloud = $cur.IsCloud -or $cur.OnlineBytes -gt 0
    foreach ($v in $list) { if ($v.IsCloud) { $hasCloud = $true; break } }
    if ($hasCloud) {
        $segs += @("$E[0;38;5;250m", ' = ', "$E[1;97m", (Format-Size ($cur.Size - $cur.OnlineBytes)), "$E[0;38;5;250m", ' on disk + ',
                   "$E[1;38;5;111m", (Format-Size $cur.OnlineBytes), "$E[0;38;5;250m", ' online-only')
    }
    $segs += @("$E[0;38;5;250m", ('   {0:N0} folders   {1:N0} files   ' -f $cur.Dirs, $cur.Files))
    if ($status.Running) {
        $segs += @("$E[1;93m", "$spin Scanning... ", "$E[0;33m",
                   ('{0:N0} folders read, {1:0.0}s' -f $status.Dirs, $status.Elapsed.TotalSeconds))
    }
    else {
        $segs += @("$E[32m", ('Scan complete ({0:0.0}s)' -f $status.Elapsed.TotalSeconds))
    }
    Add-Row $sb 2 $max $segs

    # Row 3: column headers
    $barW = [Math]::Max(10, [Math]::Min(40, [int](($W - 28) * 0.35)))
    $nameW = $max - 27 - $barW
    if ($nameW -lt 12) { $barW = [Math]::Max(4, $barW - (12 - $nameW)); $nameW = $max - 27 - $barW }
    $hdr = '  ' + '#'.PadLeft(4) + ' ' + 'Size'.PadLeft(9) + '   ' + '%'.PadLeft(6) + ' ' + 'Relative size'.PadRight($barW).Substring(0, $barW) + ' Name'
    Add-Row $sb 3 $max @("$E[4;38;5;245m", $hdr.PadRight($max))

    # Rows 4..: folder list
    $maxSize = if ($count -gt 0) { $list[0].Size } else { 0 }
    $total = $cur.Size
    for ($r = 0; $r -lt $listH; $r++) {
        $row = 4 + $r
        $i = $S.Top + $r
        if ($i -ge $count) {
            if ($r -eq 0) {
                $msg = if (-not $cur.Done) { "  $spin Reading folder..." } elseif ($cur.Denied) { '  Access denied.' } else { '  (no subfolders)' }
                Add-Row $sb $row $max @("$E[38;5;244m", $msg)
            }
            else { Add-Row $sb $row $max @('', '') }
            continue
        }
        $v = $list[$i]
        $sel = ($i -eq $idx)
        $top = ($i -lt 5)
        $bg = if ($sel) { "$E[48;5;24m" } else { "$E[49m" }
        $barColor = if ($top) { $script:TopColors[$i] } else { $script:RestColor }
        $rankStyle = if ($top) { "$E[1;38;5;$($script:TopColors[$i])m" } else { "$E[22;38;5;242m" }
        $sizeStyle = if ($top) { "$E[1;97m" } else { "$E[22;38;5;252m" }
        $nameStyle = if ($top) { "$E[1;97m" } else { "$E[22;38;5;252m" }
        if ($v.IsLink -or $v.Denied) { $nameStyle = "$E[22;38;5;244m" }

        $state = ' '; $stateStyle = "$E[38;5;244m"
        if (-not $v.Done) { $state = $spin; $stateStyle = "$E[93m" }
        elseif ($v.Denied) { $state = '!'; $stateStyle = "$E[91m" }
        elseif ($v.IsLink) { $state = '~' }

        $rank = if ($top) { "#$($i + 1)" } else { [string]($i + 1) }
        $pct = if ($total -gt 0) { '{0:0.0}%' -f ($v.Size * 100.0 / $total) } else { '' }
        $frac = if ($maxSize -gt 0) { $v.Size / $maxSize } else { 0 }
        # Bar: on-disk part in the row color, online-only part dimmed.
        $bar = Get-Bar $frac $barW
        $localCells = $barW
        if ($v.OnlineBytes -gt 0 -and $maxSize -gt 0) {
            $localCells = [int][Math]::Round(($v.Size - $v.OnlineBytes) / $maxSize * $barW)
        }
        $name = $v.Name + '\'
        if ($v.IsLink) { $name += '  (link, not followed)' }
        elseif ($v.Denied) { $name += '  (access denied)' }
        elseif ($v.IsCloud -or $v.OnlineBytes -gt 0) {
            $name += '  ({0} on disk, {1} online-only)' -f (Format-Size ($v.Size - $v.OnlineBytes)), (Format-Size $v.OnlineBytes)
        }
        if ($name.Length -gt $nameW) { $name = $name.Substring(0, $nameW - 1) + $script:Ellipsis }

        $marker = if ($sel) { "$E[1;97m> " } else { '  ' }
        Add-Row $sb $row $max @(
            $bg, '', '', $marker,
            $rankStyle, $rank.PadLeft(4), '', ' ',
            $sizeStyle, (Format-Size $v.Size).PadLeft(9), '', ' ',
            $stateStyle, $state, '', ' ',
            "$E[22;38;5;245m", $pct.PadLeft(6), '', ' ',
            "$E[38;5;$($barColor)m$E[48;5;236m", $bar.Substring(0, $localCells),
            "$E[38;5;240m", $bar.Substring($localCells), $bg, ' ',
            $nameStyle, $name
        ) $(if ($sel) { $bg } else { '' })
    }

    # Row H-1: info line or transient message
    if ($S.Message -and [Environment]::TickCount - $S.MessageAt -lt 3000) {
        Add-Row $sb ($H - 1) $max @("$E[1;93m", " $($S.Message)")
    }
    else {
        $S.Message = $null
        $pos = if ($count -gt 0) { "  |  $($idx + 1) of $count" } else { '' }
        $info = ' Files directly in this folder: {0} ({1:N0} files)' -f (Format-Size $cur.OwnBytes), $cur.OwnFiles
        if ($cur.OwnOnlineFiles -gt 0) {
            $info += ', {0} online-only ({1:N0} files)' -f (Format-Size $cur.OwnOnlineBytes), $cur.OwnOnlineFiles
        }
        $infoSegs = @("$E[38;5;244m", $info + $pos)
        # Cloud folder selected: show its full breakdown first, since the name column may be truncated.
        if ($count -gt 0 -and ($list[$idx].IsCloud -or $list[$idx].OnlineBytes -gt 0)) {
            $v = $list[$idx]
            $infoSegs = @("$E[38;5;111m", (' {0}: {1} total = {2} on disk + {3} online-only ({4:N0} files)  |' -f
                $v.Name, (Format-Size $v.Size), (Format-Size ($v.Size - $v.OnlineBytes)), (Format-Size $v.OnlineBytes), $v.OnlineFiles)) + $infoSegs
        }
        Add-Row $sb ($H - 1) $max $infoSegs
    }

    # Row H: key help
    $k = "$E[1;97;48;5;238m"; $t = "$E[0;38;5;250m"
    Add-Row $sb $H $max @($k, ' Up/Dn ', $t, ' move ', $k, ' Enter ', $t, ' open ', $k, ' Bksp ', $t, ' up ',
                           $k, ' O ', $t, ' explorer ', $k, ' R ', $t, ' rescan ', $k, ' Q ', $t, ' quit')

    [Console]::Out.Write($sb.ToString())
    [Console]::Out.Flush()
}

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
function Set-Message($S, [string]$Text) {
    $S.Message = $Text
    $S.MessageAt = [Environment]::TickCount
}

function Select-Index($S, [int]$Index) {
    $list = $S.List
    if ($null -eq $list -or $list.Length -eq 0) { return }
    $Index = [Math]::Max(0, [Math]::Min($Index, $list.Length - 1))
    $S.SelIndex = $Index
    $S.SelNode = $list[$Index].Node
}

function Open-Selected($S) {
    $list = $S.List
    if ($null -eq $list -or $list.Length -eq 0) { return }
    $v = $list[$S.SelIndex]
    if ($v.IsLink) { Set-Message $S "'$($v.Name)' is a link or junction and was not scanned."; return }
    if ($v.Denied) { Set-Message $S "Access to '$($v.Name)' was denied."; return }
    $S.Memory[$S.Current] = $S.SelNode
    $S.Current = $v.Node
    $S.SelNode = $S.Memory[$v.Node]
    $S.SelIndex = 0
    $S.Top = 0
}

function Open-Parent($S) {
    $cur = $S.Current
    $parent = $cur.Parent
    if ($null -eq $parent) { $parent = $S.UpLinks[$cur] }
    if ($null -eq $parent) {
        # Above the scanned root: scan the parent, reusing what we already have for this folder.
        $parentPath = $null
        try { $parentPath = [IO.Path]::GetDirectoryName($cur.RootPath) } catch { }
        if ([string]::IsNullOrEmpty($parentPath)) { Set-Message $S 'Already at the top level.'; return }
        $parent = $script:NodeType::CreateRoot($parentPath)
        $S.Scanners.Add($script:Scanner::Start($parent, $cur))
        $S.UpLinks[$cur] = $parent
    }
    $S.Memory[$cur] = $S.SelNode
    $S.Current = $parent
    $S.SelNode = $cur
    $S.Top = 0
}

function Restart-Scan($S) {
    $path = $S.Current.FullPath
    foreach ($sc in $S.Scanners) { $sc.Cancel() }
    $S.Scanners.Clear()
    $S.Memory.Clear()
    $S.UpLinks.Clear()
    $root = $script:NodeType::CreateRoot($path)
    $S.Scanners.Add($script:Scanner::Start($root, $null))
    $S.Current = $root
    $S.SelNode = $null
    $S.SelIndex = 0
    $S.Top = 0
}

function Open-InExplorer($S) {
    $list = $S.List
    $target = if ($null -ne $list -and $list.Length -gt 0) { $list[$S.SelIndex].Node.FullPath } else { $S.Current.FullPath }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $target)
        Set-Message $S "Opened $target"
    }
    catch { Set-Message $S "Could not open Explorer: $($_.Exception.Message)" }
}

function Invoke-Key($S, [ConsoleKeyInfo]$Key) {
    if (($Key.Modifiers -band [ConsoleModifiers]::Control) -and $Key.Key -eq [ConsoleKey]::C) { $S.Quit = $true; return }
    $page = [Math]::Max(1, $S.ListH - 1)
    switch ([string]$Key.Key) {
        'UpArrow'    { Select-Index $S ($S.SelIndex - 1); return }
        'DownArrow'  { Select-Index $S ($S.SelIndex + 1); return }
        'PageUp'     { Select-Index $S ($S.SelIndex - $page); return }
        'PageDown'   { Select-Index $S ($S.SelIndex + $page); return }
        'Home'       { Select-Index $S 0; return }
        'End'        { Select-Index $S ([int]::MaxValue); return }
        'Enter'      { Open-Selected $S; return }
        'RightArrow' { Open-Selected $S; return }
        'Backspace'  { Open-Parent $S; return }
        'LeftArrow'  { Open-Parent $S; return }
        'Escape'     { $S.Quit = $true; return }
    }
    switch ([char]::ToLowerInvariant($Key.KeyChar)) {
        'k' { Select-Index $S ($S.SelIndex - 1) }
        'j' { Select-Index $S ($S.SelIndex + 1) }
        'l' { Open-Selected $S }
        'h' { Open-Parent $S }
        'o' { Open-InExplorer $S }
        'r' { Restart-Scan $S }
        'q' { $S.Quit = $true }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Start-SpaceFinder([string]$Path) {
    if ($Host.Name -eq 'Windows PowerShell ISE Host' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'SpaceFinder needs an interactive console (it does not run in the ISE or with redirected I/O).'
    }

    if ($Path) {
        $resolved = Resolve-Path -LiteralPath $Path
        if ($resolved.Provider.Name -ne 'FileSystem') { throw "'$Path' is not a file system path." }
        $rootPath = $resolved.ProviderPath
    }
    else {
        $rootPath = (Get-Location -PSProvider FileSystem).ProviderPath
    }

    Initialize-Scanner

    $root = $script:NodeType::CreateRoot($rootPath)
    $S = @{
        Current   = $root
        SelNode   = $null
        SelIndex  = 0
        Top       = 0
        List      = $null
        ListH     = 10
        Scanners  = New-Object 'System.Collections.Generic.List[object]'
        Memory    = @{}   # folder -> last selected child
        UpLinks   = @{}   # scan root -> parent root created when navigating above it
        Message   = $null
        MessageAt = 0
        Quit      = $false
    }
    $S.Scanners.Add($script:Scanner::Start($root, $null))

    $E = $script:E
    $oldMode = $script:ConsoleHelper::EnableVirtualTerminal()
    $oldEncoding = [Console]::OutputEncoding
    $oldCtrlC = [Console]::TreatControlCAsInput
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        [Console]::TreatControlCAsInput = $true
        [Console]::Out.Write("$E[?1049h$E[?25l$E[H$E[2J")

        $lastW = 0; $lastH = 0
        $wasRunning = $true
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $dirty = $true
        while (-not $S.Quit) {
            while ([Console]::KeyAvailable) {
                Invoke-Key $S ([Console]::ReadKey($true))
                $dirty = $true
                if ($S.Quit) { break }
            }
            if ($S.Quit) { break }

            $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
            if ($w -ne $lastW -or $h -ne $lastH) {
                [Console]::Out.Write("$E[H$E[2J")
                $lastW = $w; $lastH = $h; $dirty = $true
            }

            $running = $false
            foreach ($sc in $S.Scanners) { if ($sc.IsRunning) { $running = $true; break } }
            if (($running -or $wasRunning -or $S.Message) -and $clock.ElapsedMilliseconds -ge 100) { $dirty = $true }
            $wasRunning = $running

            if ($dirty) {
                Show-Frame $S $w $h
                $clock.Restart()
                $dirty = $false
            }
            [Threading.Thread]::Sleep(15)
        }
    }
    finally {
        foreach ($sc in $S.Scanners) { $sc.Cancel() }
        [Console]::Out.Write("$E[0m$E[?25h$E[?1049l")
        [Console]::Out.Flush()
        [Console]::TreatControlCAsInput = $oldCtrlC
        [Console]::OutputEncoding = $oldEncoding
        $script:ConsoleHelper::RestoreMode($oldMode)
    }
}

# Run unless dot-sourced.
if ($MyInvocation.InvocationName -ne '.') {
    Start-SpaceFinder -Path $Path
}
