# auto_like.ps1 —— 异人之下小程序「热心异人」自动点赞
# 纯 Windows PowerShell 5.1 实现，零第三方依赖（不需要 pip / OpenCV）。
# 原理：抓小程序窗口画面 → 模板匹配找"灰色空心 ♡"→ 点击 → 校验变红 → 滚屏继续。
# 只模拟鼠标操作，不抓包、不改包、不碰接口。刷活动数据违反平台规则，风险自负。

param(
    [int]$Target = 500,                 # 目标点赞数（0 = 一直点）
    [int]$MaxClicks = 0,                # 最多点击次数保险（0 = 不限）
    [int]$MaxRuntimeMin = 0,            # 最长运行分钟数（0 = 不限）
    [string]$WindowTitle = "异人",       # 小程序窗口标题包含的字
    [double]$Fraction = 0.90,           # 心形笔画匹配命中比例（越大越严）
    [int]$Tolerance = 12,               # 笔画亮度容差（越小越严）
    [switch]$DryRun,                    # 只识别不点击
    [string]$FromImage = "",            # 调试：用已保存的截图代替实时抓屏
    [switch]$DebugScan,                 # 调试：列出所有匹配及其红/灰状态后退出
    [switch]$SaveShots,                 # 调试：每次成功点赞后存一张现场截图
    [int]$MinDelayMs = 1000,
    [int]$MaxDelayMs = 2400
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$src = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public class Frame {
    public int W, H, Stride;
    public byte[] B;
    public static Frame FromBitmap(Bitmap bmp) {
        int w = bmp.Width, h = bmp.Height;
        var f = new Frame(); f.W = w; f.H = h;
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        f.Stride = Math.Abs(data.Stride);
        f.B = new byte[f.Stride * h];
        Marshal.Copy(data.Scan0, f.B, 0, f.B.Length);
        bmp.UnlockBits(data);
        return f;
    }
    public static Frame Load(string path) {
        using (var bmp = new Bitmap(path)) { return FromBitmap(bmp); }
    }
    public static Frame Grab(int x, int y, int w, int h) {
        using (var bmp = new Bitmap(w, h)) {
            using (var g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(x, y, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            }
            return FromBitmap(bmp);
        }
    }
    public int Px(int x, int y, int c) { return B[y * Stride + x * 4 + c]; }
    public Bitmap ToBitmap() {
        var bmp = new Bitmap(W, H, PixelFormat.Format32bppArgb);
        var d = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        var row = new byte[W * 4];
        for (int y = 0; y < H; y++) {
            Array.Copy(B, y * Stride, row, 0, W * 4);
            Marshal.Copy(row, 0, new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), W * 4);
        }
        bmp.UnlockBits(d);
        return bmp;
    }
    // 等比缩放模板：不同页面/组件里心形图标的像素尺寸会差 ±20%
    public static Frame Scale(Frame src, double s) {
        int w = Math.Max(8, (int)Math.Round(src.W * s));
        int h = Math.Max(8, (int)Math.Round(src.H * s));
        using (var dst = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(dst)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                using (var sb = src.ToBitmap()) {
                    g.DrawImage(sb, new Rectangle(0, 0, w, h));
                }
            }
            return FromBitmap(dst);
        }
    }
    public void Save(string path) {
        using (var bmp = new Bitmap(W, H, PixelFormat.Format32bppArgb)) {
            var d = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            var row = new byte[W * 4];
            for (int y = 0; y < H; y++) {
                Array.Copy(B, y * Stride, row, 0, W * 4);
                Marshal.Copy(row, 0, new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), W * 4);
            }
            bmp.UnlockBits(d);
            bmp.Save(path, ImageFormat.Png);
        }
    }
}

public class Win {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint ga);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    public struct RECT { public int L, T, R, B; }
    public struct POINT { public int X; public int Y; }

    public static bool Alive(IntPtr h) { return h != IntPtr.Zero && IsWindow(h) && IsWindowVisible(h); }

    // 把窗口真正提到最上层（SetForegroundWindow 在后台进程里经常被系统拒绝）
    public static void Raise(IntPtr h) {
        ShowWindow(h, 9);
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0003);  // HWND_TOPMOST | NOSIZE | NOMOVE
        SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0003);  // HWND_NOTOPMOST
        SetForegroundWindow(h);
    }
    // 屏幕上这个点是否落在目标窗口（防止点到被遮挡的浏览器上）
    public static bool HitTarget(int x, int y, IntPtr root) {
        var p = new POINT(); p.X = x; p.Y = y;
        IntPtr under = WindowFromPoint(p);
        if (under == IntPtr.Zero) return false;
        return under == root || GetAncestor(under, 2) == root;
    }

    // 标题含关键字的可见窗口里，取面积最大的那个（小程序可能同时开多个窗口）
    public static IntPtr Find(string part) {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            var t = new StringBuilder(512);
            GetWindowTextW(h, t, 512);
            if (t.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) {
                RECT r;
                if (GetWindowRect(h, out r)) {
                    long area = (long)(r.R - r.L) * (r.B - r.T);
                    if (area > bestArea) { bestArea = area; best = h; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    public static int[] RectOf(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        return new int[] { r.L, r.T, r.R - r.L, r.B - r.T };
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(150);   // 先让窗口收到 hover，模拟人手移动
        mouse_event(0x02, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        mouse_event(0x04, 0, 0, 0, IntPtr.Zero);
    }
    public static void Scroll(int x, int y, int delta) {
        SetCursorPos(x, y);
        mouse_event(0x0800, 0, 0, delta, IntPtr.Zero);
    }
}

public class Match {
    // 返回所有匹配位置的扁平数组 [x0,y0,x1,y1,...]
    public static List<int> Scan(Frame f, Frame tpl, int minX, int maxX, double frac, int tol) {
        int tw = tpl.W, th = tpl.H;
        int total = tw * th;
        int allowedBad = total - (int)Math.Floor(total * frac);
        var hits = new List<int>();
        int x0 = Math.Max(0, minX);
        int x1 = Math.Min(f.W - tw, maxX);
        for (int y = 0; y <= f.H - th; y++) {
            for (int x = x0; x <= x1; x++) {
                int bad = 0;
                for (int ty = 0; ty < th && bad <= allowedBad; ty++) {
                    int hi = (y + ty) * f.Stride + x * 4;
                    int ti = ty * tpl.Stride;
                    for (int tx = 0; tx < tw; tx++) {
                        if (Math.Abs(f.B[hi] - tpl.B[ti]) > tol ||
                            Math.Abs(f.B[hi + 1] - tpl.B[ti + 1]) > tol ||
                            Math.Abs(f.B[hi + 2] - tpl.B[ti + 2]) > tol) {
                            bad++;
                        }
                        hi += 4; ti += 4;
                    }
                }
                if (bad <= allowedBad) { hits.Add(x); hits.Add(y); }
            }
        }
        return hits;
    }
    // 指定区域是否已经变红（点赞成功的样子）
    public static int RedPixels(Frame f, int x, int y, int w, int h) {
        int red = 0;
        for (int ty = Math.Max(0, y); ty < Math.Min(f.H, y + h); ty++) {
            for (int tx = Math.Max(0, x); tx < Math.Min(f.W, x + w); tx++) {
                int i = ty * f.Stride + tx * 4;
                int b = f.B[i], g = f.B[i + 1], r = f.B[i + 2];
                if (r > 150 && g < 140 && b < 140 && r - g > 60) red++;
            }
        }
        return red;
    }
}

// 基于亮度的形状匹配：只看"笔画像不像心形"，不受颜色/背景微调/悬停高亮影响
public class HeartMatcher {
    int[] inkX, inkY, bgX, bgY;
    public int TW, TH;
    public HeartMatcher(Frame tpl) {
        TW = tpl.W; TH = tpl.H;
        var ix = new List<int>(); var iy = new List<int>();
        var bx = new List<int>(); var by = new List<int>();
        for (int y = 0; y < tpl.H; y++) {
            for (int x = 0; x < tpl.W; x++) {
                int i = y * tpl.Stride + x * 4;
                int lum = (tpl.B[i] * 29 + tpl.B[i + 1] * 150 + tpl.B[i + 2] * 77) >> 8;
                if (lum < 205) { ix.Add(x); iy.Add(y); }        // 笔画
                else if (lum > 238) { bx.Add(x); by.Add(y); }   // 背景
            }
        }
        inkX = ix.ToArray(); inkY = iy.ToArray();
        bgX = bx.ToArray(); bgY = by.ToArray();
    }
    public int InkCount { get { return inkX.Length; } }
    public int BgCount { get { return bgX.Length; } }

    static int LumAt(Frame f, int x, int y) {
        if (x < 0 || y < 0 || x >= f.W || y >= f.H) return 255;
        int i = y * f.Stride + x * 4;
        return (f.B[i] * 29 + f.B[i + 1] * 150 + f.B[i + 2] * 77) >> 8;
    }

    public List<int> Scan(Frame f, double inkFrac, int inkTol, double bgFrac, int bgTol, int minX) {
        var hits = new List<int>();
        int nInk = inkX.Length, nBg = bgX.Length;
        int needInk = (int)Math.Ceiling(nInk * inkFrac);
        int needBg = (int)Math.Ceiling(nBg * bgFrac);
        int maxInkLum = 205 + inkTol;     // 笔画像素要比背景暗
        int minBgLum = 238 - bgTol;       // 背景像素要够亮
        for (int y = 0; y <= f.H - TH; y++) {
            for (int x = Math.Max(0, minX); x <= f.W - TW; x++) {
                int hit = 0;
                for (int k = 0; k < nInk; k++) {
                    int px = x + inkX[k], py = y + inkY[k];
                    // 1px 相位容差：同一个图标在滚动/重绘后会有半像素偏移，允许笔画落在邻格
                    if (LumAt(f, px, py) < maxInkLum ||
                        LumAt(f, px + 1, py) < maxInkLum || LumAt(f, px - 1, py) < maxInkLum ||
                        LumAt(f, px, py + 1) < maxInkLum || LumAt(f, px, py - 1) < maxInkLum) hit++;
                    if (hit + (nInk - k - 1) < needInk) { hit = -1; break; }
                }
                if (hit < needInk) continue;
                int bh = 0;
                for (int k = 0; k < nBg; k++) {
                    int lum = LumAt(f, x + bgX[k], y + bgY[k]);
                    if (lum > minBgLum) bh++;
                    if (bh + (nBg - k - 1) < needBg) { bh = -1; break; }
                }
                if (bh < needBg) continue;
                hits.Add(x); hits.Add(y);
            }
        }
        return hits;
    }
}
"@
Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies System.Drawing

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tplPath = Join-Path $here "templates\like_heart.png"
if (-not (Test-Path $tplPath)) { throw "缺少模板：$tplPath" }

[Win]::SetProcessDPIAware() | Out-Null
$tpl = [Frame]::Load($tplPath)
$tw = $tpl.W; $th = $tpl.H

# 多尺度模板：不同页面/组件的心形图标像素尺寸不一样（列表页 20px、话题详情页 16px），
# 只用一个尺度的模板会漏掉一大半，这也是"一页能点4个只点到1个"的主因。
$matchers = @()
foreach ($s in @(0.78, 0.88, 1.0, 1.14)) {
    $st = [Frame]::Scale($tpl, $s)
    $m = New-Object HeartMatcher($st)
    $matchers += [pscustomobject]@{ Scale = $s; Matcher = $m; W = $st.W; H = $st.H }
    Write-Host ("  尺度 {0,4}  →  {1}x{2}（笔画点 {3}）" -f $s, $st.W, $st.H, $m.InkCount)
}
Write-Host "模板 like_heart.png : $tw x $th，共 $($matchers.Count) 个尺度"

# ---- 定位窗口 ----
if ($FromImage -ne "") {
    if (-not (Test-Path $FromImage)) { throw "截图不存在：$FromImage" }
    $frame = [Frame]::Load((Resolve-Path $FromImage).Path)
    $winX = 0; $winY = 0
    Write-Host "调试模式：使用截图 $FromImage ($($frame.W)x$($frame.H))"
} else {
    $hwnd = [Win]::Find($WindowTitle)
    if ($hwnd -eq [IntPtr]::Zero) {
        throw "没找到标题含「$WindowTitle」的窗口。请先用 PC 微信打开小程序（点小程序右上角 … → 在新窗口中打开）。"
    }
    [Win]::Raise($hwnd)
    Start-Sleep -Milliseconds 800
    $rect = [Win]::RectOf($hwnd)
    $winX = $rect[0]; $winY = $rect[1]
    if ($rect[2] -lt 400 -or $rect[3] -lt 400) { throw "窗口太小：$($rect[2])x$($rect[3])" }
    Write-Host "窗口：($winX,$winY) $($rect[2])x$($rect[3])"
    if ($winX -lt 0 -or $winY -lt 0) {
        Write-Host "[提醒] 小程序窗口有一部分在屏幕外，建议先拖回屏幕内再跑。"
    }
}

function Get-Frame {
    if ($FromImage -ne "") { return $frame }
    try { $r = [Win]::RectOf($hwnd) } catch { Start-Sleep -Milliseconds 300; return $null }
    # 窗口被拖动/缩放时可能拿到 0 或负的尺寸，直接跳过这一轮，别崩
    if ($r[2] -lt 400 -or $r[3] -lt 400) { Start-Sleep -Milliseconds 300; return $null }
    $x = [Math]::Max(0, $r[0]); $y = [Math]::Max(0, $r[1])
    $w = $r[2] - ($x - $r[0]); $h = $r[3] - ($y - $r[1])
    $w = [Math]::Min($w, 1920 - $x); $h = [Math]::Min($h, 1080 - $y)
    if ($w -lt 400 -or $h -lt 400) { Start-Sleep -Milliseconds 300; return $null }
    if ($x -ne $winX -or $y -ne $winY) {
        Write-Host "窗口位置变化：($winX,$winY) → ($x,$y)"
        $script:winX = $x; $script:winY = $y
    }
    return [Frame]::Grab($x, $y, $w, $h)
}

function Find-Hearts($f) {
    # 全窗口扫描，多尺度：小程序窗口宽度会变，心形图标大小也会变
    # 用亮度形状匹配（容忍颜色/悬停/抗锯齿差异），比逐像素 RGB 比对更稳
    $pts = New-Object System.Collections.ArrayList
    foreach ($m in $matchers) {
        $flat = $m.Matcher.Scan($f, $Fraction, $Tolerance, 0.92, 6, [int]($f.W * 0.42))
        $w = $m.W; $h = $m.H
        for ($i = 0; $i -lt $flat.Count; $i += 2) {
            $cx = $flat[$i] + [int]($w / 2)
            $cy = $flat[$i + 1] + [int]($h / 2)
            $dup = $false
            foreach ($p in $pts) { if ([Math]::Abs($p.CX - $cx) -le 6 -and [Math]::Abs($p.CY - $cy) -le 6) { $dup = $true; break } }
            if (-not $dup) {
                [void]$pts.Add([pscustomobject]@{ X = $flat[$i]; Y = $flat[$i + 1]; CX = $cx; CY = $cy; W = $w; H = $h; Scale = $m.Scale })
            }
        }
    }
    return $pts
}

function Test-Red($f, $p) {
    $x = $p.CX - [int]($p.W / 2) - 2
    $y = $p.CY - [int]($p.H / 2) - 2
    return ([Match]::RedPixels($f, $x, $y, $p.W + 4, $p.H + 4) -ge 8)
}

# ---- 返回箭头：点进帖子详情/评论页时用来退回信息流 ----
$backPath = Join-Path $here "templates\back_arrow.png"
$backMatcher = $null
if (Test-Path $backPath) {
    $bt = [Frame]::Load($backPath)
    $backMatcher = [pscustomobject]@{ Matcher = (New-Object HeartMatcher($bt)); W = $bt.W; H = $bt.H }
    Write-Host "返回箭头模板 back_arrow.png : $($bt.W)x$($bt.H)"
}
function Find-Back($f) {
    if ($null -eq $backMatcher) { return $null }
    $flat = $backMatcher.Matcher.Scan($f, 0.90, 10, 0.90, 6, 0)
    if ($flat.Count -lt 2) { return $null }
    $best = $null
    for ($i = 0; $i -lt $flat.Count; $i += 2) {
        $cx = $flat[$i] + [int]($backMatcher.W / 2)
        $cy = $flat[$i + 1] + [int]($backMatcher.H / 2)
        if ($null -eq $best -or ($cx + $cy * 0.5) -lt ($best.CX + $best.CY * 0.5)) { $best = [pscustomobject]@{ CX = $cx; CY = $cy } }
    }
    return $best
}
function Invoke-GoBack($f) {
    $b = Find-Back $f
    if ($null -eq $b) { return $false }
    $bx = [int]($winX + $b.CX); $by = [int]($winY + $b.CY)
    if (-not [Win]::HitTarget($bx, $by, $hwnd)) { return $false }
    Write-Host ("检测到返回箭头 ({0},{1}) → 点一下退回信息流" -f $bx, $by)
    try { [Win]::Click($bx, $by) } catch { return $false }
    Start-Sleep -Milliseconds 1500
    return $true
}

# ---- 主循环 ----
$liked = 0
$miss = 0
$emptyScrolls = 0
$emptyRetry = 0
$clicked = 0
$raiseTries = 0
$totalMiss = 0
$bad = @()
$lastY = -1000
$centerX = $null
$centerY = $null
$startTime = Get-Date
$recover = 0
$lostTries = 0
$lastReport = 0
Write-Host ("目标 {0} 个赞；{1}" -f $(if ($Target -le 0) { "不限" } else { $Target }), $(if ($DryRun) { "DryRun：只识别不点击" } else { "窗口请保持在前台，把鼠标移开" }))
if (-not $DryRun -and $FromImage -eq "") { Start-Sleep -Seconds 2 }

while (($Target -le 0 -or $liked -lt $Target) -and ($MaxClicks -le 0 -or $clicked -lt $MaxClicks)) {
    # 运行时长上限
    if ($MaxRuntimeMin -gt 0 -and ((Get-Date) - $startTime).TotalMinutes -ge $MaxRuntimeMin) {
        Write-Host "到达运行时长上限 $MaxRuntimeMin 分钟，结束。"
        break
    }
    # 窗口没了/被关掉：自动重新找，找不到就等，不退出
    if ($FromImage -eq "" -and $DryRun -eq $false -and -not [Win]::Alive($hwnd)) {
        Write-Host "小程序窗口不见了，重新查找…"
        $hwnd = [Win]::Find($WindowTitle)
        if ($hwnd -eq [IntPtr]::Zero) {
            $lostTries++
            Write-Host ("没找到标题含「{0}」的窗口，5 秒后重试（第 {1} 次）" -f $WindowTitle, $lostTries)
            Start-Sleep -Seconds 5
            if ($lostTries -gt 60) { Write-Host "找了 5 分钟还没找到窗口，结束。"; break }
            continue
        }
        $lostTries = 0
        [Win]::Raise($hwnd)
        Start-Sleep -Milliseconds 800
    }
    $f = Get-Frame
    if ($null -eq $f) {
        Write-Host "窗口正在被拖动/缩放或尺寸异常，等它稳定…"
        Start-Sleep -Milliseconds 500
        continue
    }
    if ($null -eq $centerX) { $centerX = [int]($f.W * 0.72); $centerY = [int]($f.H * 0.6) }

    try { $hearts = @(Find-Hearts $f) } catch {
        Write-Host "识别这一步出错：$($_.Exception.Message)，1 秒后继续"
        Start-Sleep -Milliseconds 1000
        continue
    }
    if ($DebugScan) {
        foreach ($h in $hearts) {
            $r = Test-Red $f $h
            Write-Host ("  ♡ 窗口({0},{1}) 屏幕({2},{3}) 尺寸 {4}x{5} 尺度{6} red={7}" -f $h.X, $h.Y, ($winX + $h.CX), ($winY + $h.CY), $h.W, $h.H, $h.Scale, $r)
        }
        Write-Host ("共匹配 {0} 个；窗口 {1}x{2} @ ({3},{4})" -f $hearts.Count, $f.W, $f.H, $winX, $winY)
        $bk = Find-Back $f
        Write-Host ("返回箭头：{0}" -f $(if ($null -eq $bk) { "未找到" } else { "($($bk.CX),$($bk.CY))" }))
        break
    }
    # 只保留灰的（未点的），并跳过点过没反应的
    $fresh = @()
    foreach ($h in $hearts) {
        if (Test-Red $f $h) { continue }
        $skip = $false
        foreach ($b in $bad) { if ([Math]::Abs($b.CX - $h.CX) -le 6 -and [Math]::Abs($b.CY - $h.CY) -le 6) { $skip = $true; break } }
        if (-not $skip) { $fresh += $h }
    }

    if ($fresh.Count -eq 0) {
        if ($DryRun -or $FromImage -ne "") {
            Write-Host "本屏没有识别到可点的 ♡。"
            break
        }
        if ($hearts.Count -gt 0) {
            # 识别到心形但全是红心/无效点 → 这一屏确实点完了，直接滚
            $emptyRetry = 0
            $emptyScrolls++
            $bad = @()
            Write-Host ("本屏 {0} 个心都点过了 → 向下滚动 (连续 {1} 次)" -f $hearts.Count, $emptyScrolls)
        } else {
            # 一个都没识别到：可能是刚点赞后的 toast/动画/重绘，先多试几次再滚（否则一页会漏点）
            $emptyRetry++
            if ($emptyRetry -lt 4) {
                Write-Host "本屏暂未识别到灰心，稍等重试 ($emptyRetry/4)"
                Start-Sleep -Milliseconds 650
                continue
            }
            $emptyRetry = 0
            $emptyScrolls++
            $bad = @()
            Write-Host "本屏没识别到灰心 → 向下滚动 (连续 $emptyScrolls 次)"
        }
        # 连续多屏没得点：不退出，回滚到顶部重新扫；每 3 次等一会儿让新帖刷出来
        if ($emptyScrolls -ge 6) {
            $emptyScrolls = 0
            $bad = @()
            $recover++
            Write-Host ("连续多屏没得点 → 第 {0} 次自救：滚回顶部重新扫" -f $recover)
            if ($FromImage -eq "") {
                for ($i = 0; $i -lt 14; $i++) {
                    [Win]::Scroll([int]($winX + $centerX), [int]($winY + $centerY), (Get-Random -Minimum 500 -Maximum 800))
                    Start-Sleep -Milliseconds 90
                }
            }
            Start-Sleep -Milliseconds 1600
            if ($recover % 3 -eq 0) {
                Write-Host "连续自救多次，等 40 秒让列表刷出新内容…"
                Start-Sleep -Seconds 40
            }
            if ($recover % 9 -eq 0) {
                Write-Host "[提醒] 已经自救很多次了，当前页可能不是信息流（比如点进了帖子详情/百科页），建议手动按一下返回再继续。脚本会一直等着。"
            }
            continue
        }
        if ($FromImage -eq "") {
            [Win]::Scroll([int]($winX + $centerX), [int]($winY + $centerY), -(Get-Random -Minimum 300 -Maximum 450))
        }
        Start-Sleep -Milliseconds 1300
        continue
    }
    $emptyScrolls = 0
    $emptyRetry = 0

    # 从上往下依次点，避免来回跳；优先挑没有被别的窗口挡住的那颗
    $fresh = $fresh | Sort-Object CY
    $pick = $null
    if ($DryRun -or $FromImage -ne "") {
        $pick = $fresh[0]
    } else {
        foreach ($h in $fresh) {
            if ([Win]::HitTarget([int]($winX + $h.CX), [int]($winY + $h.CY), $hwnd)) { $pick = $h; break }
        }
    }
    if ($null -eq $pick) {
        $raiseTries++
        Write-Host "这一屏的心都被别的窗口挡住了 → 把小程序提到最前（第 $raiseTries 次）"
        [Win]::Raise($hwnd)
        Start-Sleep -Milliseconds 900
        if ($raiseTries -ge 3) {
            $raiseTries = 0
            $emptyScrolls++
            Write-Host "还是被挡住，先滚一屏试试（窗口最好拖到屏幕内、别被压住）"
            [Win]::Scroll([int]($winX + $centerX), [int]($winY + $centerY), -(Get-Random -Minimum 300 -Maximum 450))
            Start-Sleep -Milliseconds 1300
        }
        continue
    }
    $raiseTries = 0
    $cx = [int]($winX + $pick.CX)
    $cy = [int]($winY + $pick.CY)
    $hw = [int]($pick.W / 2); $hh = [int]($pick.H / 2)

    if ($DryRun -or $FromImage -ne "") {
        Write-Host ("[识别] ♡ 共 {0} 个，点 ({1},{2})" -f $fresh.Count, $cx, $cy)
        Start-Sleep -Milliseconds 600
        break
    }

    # 点一下，校验是否变红；没反应就在同一点再补一下（页面上偶发丢点击）
    $ok = $false
    for ($attempt = 0; $attempt -lt 2 -and -not $ok; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 250 }
        try { [Win]::Click($cx, $cy + ($attempt * 2)) } catch { Write-Host "点击失败：$($_.Exception.Message)" }
        $clicked++
        for ($k = 0; $k -lt 3 -and -not $ok; $k++) {
            Start-Sleep -Milliseconds 380
            try {
                $check = [Frame]::Grab($cx - $hw - 6, $cy - $hh - 6, $pick.W + 12, $pick.H + 12)
                if ([Match]::RedPixels($check, 0, 0, $check.W, $check.H) -ge 8) { $ok = $true }
            } catch { Start-Sleep -Milliseconds 150 }
        }
    }
    if ($ok) {
        $liked++
        $miss = 0
        $totalMiss = 0
        Write-Host ("{0} 点赞成功 {1}/{2}" -f (Get-Date -Format "HH:mm:ss"), $liked, $(if ($Target -le 0) { "∞" } else { $Target }))
        if ($SaveShots) {
            $dir = Join-Path $here "captures"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $f.Save((Join-Path $dir ("ok_{0:HHmmss}.png" -f (Get-Date))))
        }
    } else {
        $miss++
        $totalMiss++
        $bad += [pscustomobject]@{ CX = $pick.CX; CY = $pick.CY }
        $shot = Join-Path (Join-Path $here "captures") ("fail_{0}.png" -f (Get-Date -Format "HHmmss"))
        New-Item -ItemType Directory -Force -Path (Split-Path $shot) | Out-Null
        $f.Save($shot)
        Write-Host ("{0} 点 ({1},{2}) 没反应，跳过这颗（累计 {3} 次）；截图：{4}" -f (Get-Date -Format "HH:mm:ss"), $cx, $cy, $totalMiss, $shot)
        # 连着点不动，多半是误进了帖子详情/评论页（那是评论的赞，不算数）→ 点返回键退回信息流
        if ($totalMiss -ge 3 -and $FromImage -eq "") {
            $f2 = Get-Frame
            if ($null -ne $f2 -and (Invoke-GoBack $f2)) {
                $totalMiss = 0
                $miss = 0
                $bad = @()
                $emptyScrolls = 0
                Write-Host "退回信息流，继续。"
                continue
            }
        }
        # 点不动不再直接停：清空黑名单、滚一屏、换个位置继续
        if ($totalMiss -ge 10) {
            $totalMiss = 0
            $bad = @()
            $clicked = [Math]::Max(0, $clicked - 1)
            Write-Host "累计多次点击无反应 → 清空黑名单、滚一屏后继续（不退出）"
            if ($FromImage -eq "") {
                [Win]::Scroll([int]($winX + $centerX), [int]($winY + $centerY), -(Get-Random -Minimum 300 -Maximum 450))
            }
            Start-Sleep -Milliseconds 1200
        }
    }
    Start-Sleep -Milliseconds (Get-Random -Minimum $MinDelayMs -Maximum $MaxDelayMs)
}

Write-Host ("结束：成功 {0}，点击 {1}，自救 {2} 次，用时 {3:N1} 分钟" -f $liked, $clicked, $recover, ((Get-Date) - $startTime).TotalMinutes)
