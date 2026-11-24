# Draws app.ico (16-256 px) from the same shapes as the tablet's launcher icon
# (android-receiver/.../drawable/ic_launcher_*.xml, ported from the Mac icon):
# an indigo-violet tile, a monitor and a tablet, and one amber window spanning both.
# Run once after changing the design; app.ico is committed and used by build.ps1.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
public static class IconArt {
    static GraphicsPath RR(float x, float y, float w, float h, float r) {
        var p = new GraphicsPath(); float d = Math.Min(2 * r, Math.Min(w, h));
        if (d <= 0) { p.AddRectangle(new RectangleF(x, y, w, h)); return p; }
        p.AddArc(x, y, d, d, 180, 90); p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90); p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
    static Color C(uint argb) { return Color.FromArgb((int)argb); }
    public static Bitmap Draw(int size) {
        var b = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(b)) {
            g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            float pad = size * 0.04f, t = size - 2 * pad;
            using (var tile = RR(pad, pad, t, t, t * 0.22f)) {
                using (var br = new LinearGradientBrush(new PointF(0, pad), new PointF(0, pad + t), C(0xFF7A63F2), C(0xFF3B2A9E))) g.FillPath(br, tile);
                g.SetClip(tile);
                using (var sheen = new LinearGradientBrush(new PointF(0, pad), new PointF(0, pad + t * 0.37f + 1), C(0x29FFFFFF), C(0x00FFFFFF)))
                    g.FillRectangle(sheen, pad, pad, t, t * 0.37f);
                g.ResetClip();
            }
            // Map the 108-unit icon viewport so the artwork (x 25.9-82.1, y 38-70) fills ~78 % of the tile.
            float s = t * 0.78f / 56.2f, ox = pad + (t - 56.2f * s) / 2 - 25.9f * s, oy = pad + (t - 31.9f * s) / 2 - 38f * s;
            g.TranslateTransform(ox, oy); g.ScaleTransform(s, s);
            Action<uint, float, float, float, float, float> fill = (col, x, y, w, h, r) => { using (var p = RR(x, y, w, h, r)) using (var br = new SolidBrush(C(col))) g.FillPath(br, p); };
            fill(0xFFE9E6FF, 40.32f, 63.04f, 6.69f, 5.33f, 0.61f);     // monitor neck
            fill(0xFFFFFFFF, 33.02f, 66.84f, 20.07f, 3.04f, 1.52f);    // monitor foot
            fill(0xFFFFFFFF, 25.88f, 37.96f, 34.96f, 26.61f, 3.5f);    // monitor body
            fill(0xFFFFFFFF, 62.67f, 47.08f, 19.45f, 17.48f, 3.19f);   // tablet body
            fill(0xFF1D1458, 28.01f, 40.09f, 30.70f, 22.34f, 1.67f);   // monitor screen
            fill(0xFF1D1458, 64.26f, 48.68f, 16.26f, 14.28f, 1.82f);   // tablet screen
            foreach (var scr in new[] { new RectangleF(28.01f, 40.09f, 30.70f, 22.34f), new RectangleF(64.26f, 48.68f, 16.26f, 14.28f) }) {
                using (var clip = RR(scr.X, scr.Y, scr.Width, scr.Height, 1.7f)) {
                    var saved = g.Clip; g.SetClip(clip, CombineMode.Replace);
                    using (var win = RR(42.44f, 51.64f, 53.21f, 24.32f, 1.98f))
                    using (var br = new LinearGradientBrush(new PointF(0, 51.64f), new PointF(0, 75.96f), C(0xFFFFC83D), C(0xFFFF8A3D))) g.FillPath(br, win);
                    using (var bar = new SolidBrush(C(0x61FFFFFF))) g.FillRectangle(bar, 42.45f, 51.64f, 53.2f, 3.5f);
                    g.Clip = saved;
                }
            }
            if (size >= 32) {
                fill(0xFF4FD8C4, 30.29f, 42.37f, 9.88f, 2.28f, 1.14f);
                fill(0x8C4FD8C4, 30.29f, 46.17f, 6.38f, 2.28f, 1.14f);
            }
        }
        return b;
    }
}
'@
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { $ms = New-Object IO.MemoryStream; ([IconArt]::Draw($s)).Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
$out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$pngs[$i].Length); $w.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'app.ico'), $out.ToArray())
([IconArt]::Draw(256)).Save((Join-Path $PSScriptRoot '..\..\.verification\icon-256.png'))
"Wrote app.ico ($($out.Length) bytes)"
