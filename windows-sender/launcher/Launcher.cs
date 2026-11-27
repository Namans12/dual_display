// Extended Display launcher: a small WinForms window that configures and runs
// ExtendedDisplaySender.exe.
//
// Lifecycle
//   open   -> load the virtual display driver (SetupAPI, off the UI thread), then
//             run "sender --cleanup" (screen off, speakers restored). Start enables.
//   Start  -> spawn the sender with the chosen flags. No driver work, no sleeps.
//             The sender switches the virtual screen on/off itself.
//   Stop   -> signal the sender's stop event, wait (background), Kill as a last
//             resort, then "--cleanup".
//   close  -> hide the window at once; stop sender, cleanup, unload the driver in
//             the background (capped), then exit.
//
// Threading: every state change happens on the UI thread. Blocking work (driver
// calls, process waits, --cleanup) runs on worker threads and reports back with
// BeginInvoke. Nothing on the UI thread waits for a process or sleeps.
//
// DPI: per-monitor-V2 (manifest). All layout is stored in 96-dpi units and
// re-applied from those base values whenever the window's DPI changes, so there
// is no rounding drift when dragging between monitors. Fonts are created in
// pixels so they do not depend on the system DPI.

using System;
using System.Reflection;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// Shown by Explorer (file properties) and Task Manager.
[assembly: AssemblyTitle("DualSlate")]
[assembly: AssemblyProduct("DualSlate")]
[assembly: AssemblyCompany("Namans12")]
[assembly: AssemblyDescription("DualSlate - use an Android tablet as an extended display")]
[assembly: AssemblyVersion("0.11.1.0")]
[assembly: AssemblyFileVersion("0.11.1.0")]

namespace ExtendedDisplay
{
    // ── Virtual display driver (IddCx "Virtual Display Driver", Root\MttVDD) ──
    static class Vdd
    {
        public enum Result { Ok, NotInstalled, Failed }

        const string HardwareId = @"Root\MttVDD";
        const string FriendlyName = "Virtual Display Driver";
        static readonly Guid DisplayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");

        const int DIGCF_PRESENT = 0x2;
        const int SPDRP_DEVICEDESC = 0x0, SPDRP_HARDWAREID = 0x1, SPDRP_FRIENDLYNAME = 0xC;
        const int DIF_PROPERTYCHANGE = 0x12;
        const int DICS_ENABLE = 1, DICS_DISABLE = 2, DICS_FLAG_GLOBAL = 1;
        const int DN_STARTED = 0x8, CM_PROB_DISABLED = 22, CM_PROB_HARDWARE_DISABLED = 0x16;

        [StructLayout(LayoutKind.Sequential)]
        struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)]
        struct SP_CLASSINSTALL_HEADER { public int cbSize; public int InstallFunction; }
        [StructLayout(LayoutKind.Sequential)]
        struct SP_PROPCHANGE_PARAMS { public SP_CLASSINSTALL_HEADER Header; public int StateChange; public int Scope; public int HwProfile; }

        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr SetupDiGetClassDevs(ref Guid cls, string enumerator, IntPtr hwnd, int flags);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiEnumDeviceInfo(IntPtr set, int index, ref SP_DEVINFO_DATA d);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA d, int prop, out int type, byte[] buf, int size, out int req);
        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref SP_DEVINFO_DATA d, StringBuilder id, int size, out int req);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiSetClassInstallParams(IntPtr set, ref SP_DEVINFO_DATA d, ref SP_PROPCHANGE_PARAMS p, int size);
        [DllImport("setupapi.dll", SetLastError = true)]
        static extern bool SetupDiCallClassInstaller(int func, IntPtr set, ref SP_DEVINFO_DATA d);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
        [DllImport("cfgmgr32.dll")]
        static extern int CM_Get_DevNode_Status(out int status, out int problem, int devInst, int flags);

        public class Info { public string InstanceId = ""; public bool Started; public int Problem; }

        // Walk the display class and match by hardware ID (or friendly name), so the
        // instance number (ROOT\DISPLAY\0000 here) can differ between PCs.
        public static bool Find(out Info info)
        {
            info = null;
            Guid cls = DisplayClass;
            IntPtr set = SetupDiGetClassDevs(ref cls, null, IntPtr.Zero, DIGCF_PRESENT);
            if (set == new IntPtr(-1)) return false;
            try
            {
                var d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                for (int i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++)
                {
                    bool match = false;
                    foreach (string id in Multi(set, ref d, SPDRP_HARDWAREID))
                        if (string.Equals(id, HardwareId, StringComparison.OrdinalIgnoreCase)) match = true;
                    if (!match)
                        foreach (int p in new[] { SPDRP_FRIENDLYNAME, SPDRP_DEVICEDESC })
                            foreach (string n in Multi(set, ref d, p))
                                if (n.IndexOf(FriendlyName, StringComparison.OrdinalIgnoreCase) >= 0) match = true;
                    if (!match) continue;
                    var sb = new StringBuilder(260); int req;
                    SetupDiGetDeviceInstanceId(set, ref d, sb, sb.Capacity, out req);
                    info = new Info { InstanceId = sb.ToString() };
                    int st, pr;
                    if (CM_Get_DevNode_Status(out st, out pr, d.DevInst, 0) == 0)
                    { info.Started = (st & DN_STARTED) != 0 && pr == 0; info.Problem = pr; }
                    return true;
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
            return false;
        }

        static string[] Multi(IntPtr set, ref SP_DEVINFO_DATA d, int prop)
        {
            int type, req;
            var buf = new byte[1024];
            if (!SetupDiGetDeviceRegistryProperty(set, ref d, prop, out type, buf, buf.Length, out req)) return new string[0];
            return Encoding.Unicode.GetString(buf, 0, Math.Min(req, buf.Length)).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
        }

        static bool Change(string instanceId, int state)
        {
            Guid cls = DisplayClass;
            IntPtr set = SetupDiGetClassDevs(ref cls, null, IntPtr.Zero, DIGCF_PRESENT);
            if (set == new IntPtr(-1)) return false;
            try
            {
                var d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
                for (int i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++)
                {
                    var sb = new StringBuilder(260); int req;
                    SetupDiGetDeviceInstanceId(set, ref d, sb, sb.Capacity, out req);
                    if (!string.Equals(sb.ToString(), instanceId, StringComparison.OrdinalIgnoreCase)) continue;
                    var p = new SP_PROPCHANGE_PARAMS();
                    p.Header.cbSize = Marshal.SizeOf(typeof(SP_CLASSINSTALL_HEADER));
                    p.Header.InstallFunction = DIF_PROPERTYCHANGE;
                    p.StateChange = state; p.Scope = DICS_FLAG_GLOBAL; p.HwProfile = 0;
                    return SetupDiSetClassInstallParams(set, ref d, ref p, Marshal.SizeOf(typeof(SP_PROPCHANGE_PARAMS)))
                        && SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, set, ref d);
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
            return false;
        }

        static bool InState(bool wantStarted)
        {
            Info i;
            if (!Find(out i)) return false;
            return wantStarted ? i.Started : !i.Started;
        }

        // Enable or disable, then confirm the device really reached that state
        // (polling, not sleeping blindly). SetupAPI first; pnputil if it did not take.
        public static Result Set(bool enable, out string detail)
        {
            detail = "";
            Info info;
            if (!Find(out info)) return Result.NotInstalled;
            if (InState(enable)) return Result.Ok;
            bool ok = Change(info.InstanceId, enable ? DICS_ENABLE : DICS_DISABLE);
            if (ok && Wait(enable, 4000)) return Result.Ok;
            try
            {
                var psi = new ProcessStartInfo("pnputil.exe", (enable ? "/enable-device " : "/disable-device ") + "\"" + info.InstanceId + "\"")
                { UseShellExecute = false, CreateNoWindow = true };
                using (var p = Process.Start(psi)) { if (!p.WaitForExit(8000)) { try { p.Kill(); } catch { } } }
            }
            catch (Exception ex) { detail = ex.Message; }
            if (Wait(enable, 4000)) return Result.Ok;
            detail = "device would not " + (enable ? "start" : "stop") + (detail.Length > 0 ? " (" + detail + ")" : "");
            return Result.Failed;
        }

        static bool Wait(bool enable, int ms)
        {
            var sw = Stopwatch.StartNew();
            do { if (InState(enable)) return true; Thread.Sleep(25); } while (sw.ElapsedMilliseconds < ms);
            return false;
        }
    }

    // ── DPI helpers ───────────────────────────────────────────────────────
    static class Dpi
    {
        [DllImport("user32.dll")] static extern int GetDpiForSystem();
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point pt, int flags);

        public static int ForSystem() { try { return GetDpiForSystem(); } catch { return 96; } }

        public static int ForPoint(Point p)
        {
            try
            {
                uint x, y;
                if (GetDpiForMonitor(MonitorFromPoint(p, 2), 0, out x, out y) == 0 && x > 0) return (int)x;
            }
            catch { }
            return ForSystem();
        }
    }

    // ── Palette and fonts ─────────────────────────────────────────────────
    static class Ui
    {
        public static float K = 1f;  // current scale (dpi / 96)
        public static readonly Color Bg = Color.FromArgb(243, 243, 243);
        public static readonly Color Card = Color.White;
        public static readonly Color CardBorder = Color.FromArgb(228, 228, 228);
        public static readonly Color Text = Color.FromArgb(27, 27, 27);
        public static readonly Color Muted = Color.FromArgb(96, 96, 96);
        public static readonly Color Faint = Color.FromArgb(160, 160, 160);
        public static readonly Color Accent = Color.FromArgb(0, 103, 192);
        public static readonly Color AccentHover = Color.FromArgb(25, 117, 197);
        public static readonly Color AccentDown = Color.FromArgb(50, 131, 202);
        public static readonly Color Danger = Color.FromArgb(196, 43, 28);
        public static readonly Color DangerHover = Color.FromArgb(208, 62, 47);
        public static readonly Color DangerDown = Color.FromArgb(218, 90, 77);
        public static readonly Color Disabled = Color.FromArgb(204, 204, 204);

        static readonly HashSet<string> installed = new HashSet<string>();
        public static readonly string Face, Semi, Mono = "Consolas";
        static Ui()
        {
            using (var c = new InstalledFontCollection())
                foreach (var f in c.Families) installed.Add(f.Name);
            Face = installed.Contains("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";
            Semi = installed.Contains("Segoe UI Semibold") ? "Segoe UI Semibold" : Face;
            if (!installed.Contains(Mono)) Mono = "Courier New";
        }

        static readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();
        public static Font Font(string face, float px, FontStyle style)
        {
            float size = (float)Math.Round(px * K * 2) / 2f;  // half-pixel steps
            string key = face + "|" + size + "|" + (int)style;
            Font f;
            if (!fonts.TryGetValue(key, out f)) { f = new Font(face, size, style, GraphicsUnit.Pixel); fonts[key] = f; }
            return f;
        }

        public static int S(float v) { return (int)Math.Round(v * K); }

        public static GraphicsPath Round(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static Color Blend(Color a, Color b, float t)
        {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }
    }

    // ── Custom controls (owner-drawn so they are crisp and DPI-exact) ────
    class Card : Panel
    {
        public Card()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Ui.Bg;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Ui.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (var path = Ui.Round(r, Ui.S(8)))
            using (var fill = new SolidBrush(Ui.Card))
            using (var pen = new Pen(Ui.CardBorder, Math.Max(1f, Ui.K * 0.75f)))
            { g.FillPath(fill, path); g.DrawPath(pen, path); }
        }
    }

    class FlatCheck : CheckBox
    {
        bool hot;
        public FlatCheck()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat; AutoSize = false; BackColor = Ui.Card;
        }
        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            DrawGlyph(g, Checked, false, Enabled, hot, Focused && ShowFocusCues, new Rectangle(0, 0, Width, Height));
            float box = Ui.S(16), gap = Ui.S(9);
            var tr = new Rectangle((int)(box + gap), 0, Math.Max(1, Width - (int)(box + gap)), Height);
            TextRenderer.DrawText(g, Text, Font, tr, Enabled ? Ui.Text : Ui.Faint,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }

        public static void DrawGlyph(Graphics g, bool on, bool radio, bool enabled, bool hot, bool focus, Rectangle area)
        {
            float box = Ui.S(16), line = Math.Max(1f, Ui.K * 1.1f);
            float x = 0.5f + line / 2, y = (area.Height - box) / 2f + line / 2, s = box - line - 1;
            var r = new RectangleF(x, y, s, s);
            Color accent = enabled ? Ui.Accent : Ui.Disabled;
            Color edge = enabled ? (hot ? Ui.Muted : Color.FromArgb(138, 138, 138)) : Ui.Disabled;
            using (var pen = new Pen(on ? accent : edge, line))
            using (var fill = new SolidBrush(on && !radio ? accent : Color.White))
            {
                if (radio)
                {
                    g.FillEllipse(fill, r); g.DrawEllipse(pen, r);
                    if (on)
                    {
                        float d = s * 0.5f;
                        using (var dot = new SolidBrush(accent))
                            g.FillEllipse(dot, r.X + (s - d) / 2, r.Y + (s - d) / 2, d, d);
                    }
                }
                else
                {
                    using (var path = Ui.Round(r, Ui.S(4)))
                    { g.FillPath(fill, path); g.DrawPath(pen, path); }
                    if (on)
                        using (var tick = new Pen(Color.White, Math.Max(1.5f, Ui.K * 1.7f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                            g.DrawLines(tick, new[] {
                                new PointF(r.X + s * 0.25f, r.Y + s * 0.53f),
                                new PointF(r.X + s * 0.44f, r.Y + s * 0.72f),
                                new PointF(r.X + s * 0.76f, r.Y + s * 0.30f) });
                }
            }
            if (focus)
            {
                var f = RectangleF.Inflate(r, Ui.K * 2.5f, Ui.K * 2.5f);
                using (var pen = new Pen(Ui.Accent, Math.Max(1f, Ui.K)))
                    if (radio) g.DrawEllipse(pen, f);
                    else using (var path = Ui.Round(f, Ui.S(6))) g.DrawPath(pen, path);
            }
        }
    }

    class FlatRadio : RadioButton
    {
        bool hot;
        public FlatRadio()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat; AutoSize = false; BackColor = Ui.Card;
        }
        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            FlatCheck.DrawGlyph(g, Checked, true, Enabled, hot, Focused && ShowFocusCues, new Rectangle(0, 0, Width, Height));
            float box = Ui.S(16), gap = Ui.S(9);
            var tr = new Rectangle((int)(box + gap), 0, Math.Max(1, Width - (int)(box + gap)), Height);
            TextRenderer.DrawText(g, Text, Font, tr, Enabled ? Ui.Text : Ui.Faint,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }
    }

    // A label drawn without GDI's side padding, which grows with the font size: the
    // large title otherwise started visibly right of the smaller subtitle and the
    // section headings. With it, all of them start exactly at their x.
    class TightLabel : Label
    {
        public bool Wraps;  // word-wrap instead of one ellipsised line
        protected override void OnPaint(PaintEventArgs e)
        {
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor, BackColor,
                TextFormatFlags.NoPadding | TextFormatFlags.Left | TextFormatFlags.Top |
                (Wraps ? TextFormatFlags.WordBreak : TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis));
        }
    }

    class InfoDot : Control
    {
        bool hot;
        public InfoDot()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Ui.Card; Cursor = Cursors.Hand; TabStop = false;
        }
        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float line = Math.Max(1f, Ui.K * 1.1f);
            float d = Math.Min(Width, Height) - line - 1;
            var r = new RectangleF((Width - d) / 2, (Height - d) / 2, d, d);
            Color c = hot ? Ui.Accent : Color.FromArgb(150, 150, 150);
            using (var pen = new Pen(c, line)) g.DrawEllipse(pen, r);
            TextRenderer.DrawText(g, "i", Font, new Rectangle(0, 0, Width, Height), c,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    enum Tone { Neutral, Busy, Good, Warn, Bad }

    class Pill : Control
    {
        Tone tone = Tone.Neutral;
        public Pill()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Ui.Bg; TabStop = false;
        }
        public Tone Tone { get { return tone; } set { tone = value; Invalidate(); } }
        public int PreferredWidth()
        {
            return TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Width + Ui.S(40);
        }
        static void Colors(Tone t, out Color bg, out Color fg, out Color dot)
        {
            switch (t)
            {
                case Tone.Busy: bg = Color.FromArgb(220, 235, 250); fg = Color.FromArgb(11, 92, 173); dot = Ui.Accent; break;
                case Tone.Good: bg = Color.FromArgb(223, 243, 226); fg = Color.FromArgb(14, 100, 30); dot = Color.FromArgb(16, 124, 16); break;
                case Tone.Warn: bg = Color.FromArgb(255, 241, 214); fg = Color.FromArgb(125, 75, 0); dot = Color.FromArgb(201, 122, 0); break;
                case Tone.Bad: bg = Color.FromArgb(253, 231, 233); fg = Color.FromArgb(164, 38, 44); dot = Ui.Danger; break;
                default: bg = Color.FromArgb(232, 232, 232); fg = Color.FromArgb(70, 70, 70); dot = Color.FromArgb(138, 138, 138); break;
            }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Ui.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color bg, fg, dot; Colors(tone, out bg, out fg, out dot);
            var r = new RectangleF(0, 0, Width - 1, Height - 1);
            using (var path = Ui.Round(r, Height / 2f))
            using (var b = new SolidBrush(bg)) g.FillPath(b, path);
            float dd = Ui.S(8);
            using (var b = new SolidBrush(dot)) g.FillEllipse(b, Ui.S(14), (Height - dd) / 2f, dd, dd);
            int tx = Ui.S(14) + (int)dd + Ui.S(8);
            TextRenderer.DrawText(g, Text, Font, new Rectangle(tx, 0, Math.Max(1, Width - tx), Height), fg,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    class BigButton : Button
    {
        bool hot, down;
        public bool Danger;
        public BigButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat; BackColor = Ui.Bg;
        }
        protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Ui.Bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color fill, fg;
            if (!Enabled) { fill = Ui.Disabled; fg = Color.FromArgb(120, 120, 120); }
            else
            {
                fg = Color.White;
                if (Danger) fill = down ? Ui.DangerDown : hot ? Ui.DangerHover : Ui.Danger;
                else fill = down ? Ui.AccentDown : hot ? Ui.AccentHover : Ui.Accent;
            }
            var r = new RectangleF(0, 0, Width - 1, Height - 1);
            using (var path = Ui.Round(r, Ui.S(7)))
            using (var b = new SolidBrush(fill)) g.FillPath(b, path);
            if (Focused && ShowFocusCues)
            {
                var f = RectangleF.Inflate(r, -Ui.K * 3, -Ui.K * 3);
                using (var path = Ui.Round(f, Ui.S(5)))
                using (var pen = new Pen(Color.FromArgb(200, 255, 255, 255), Math.Max(1f, Ui.K))) g.DrawPath(pen, path);
            }
            TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        }
    }

    // ── The window ────────────────────────────────────────────────────────
    public class MainForm : Form
    {
        // Base (96 dpi) client size.
        const int BaseW = 720, BaseH = 520;

        enum AppState { Loading, Ready, Starting, Running, Stopping, Fault, Closing }

        class Item { public Control C; public Rectangle B; public float FontPx; public string Face; public FontStyle Style; public bool Fixed; }
        readonly List<Item> items = new List<Item>();

        // Test / verification switches (never set by shortcuts or the installer).
        readonly bool noDriver;     // --no-driver: skip driver, cleanup and all sender work
        readonly string demo;       // --demo=<state>: show a simulated state
        readonly string shotPath, shot2Path, moveTo;
        readonly bool onPrimary;   // --primary: open on the primary monitor regardless of the cursor

        FlatRadio rbUsb, rbWifi, rbBestRes, rbBalanced, rbSmooth;
        FlatCheck chkUdp, chkTouch, chkHevc, chkHdr, chkEncrypt, chkAudio, chkMute;
        TextBox txtIp;
        NumericUpDown numDelay;
        Label lblDelay, lblIpCap, lblCodeCap, lblCode, lblDetail, lblTitle, lblSub;
        LinkLabel lnkNewCode;
        BigButton btnMain;
        Pill pill;
        Card cardConn, cardQual, cardOpt;
        ToolTip tip;

        AppState state = AppState.Loading;
        bool locked;
        bool closing;
        bool dirty;                 // a sender ran since the last --cleanup
        string pairCode = "";
        Process sender;
        readonly string exePath;
        string liveFps = "", liveState = "", liveMode = "", liveNote = "";
        readonly object driverLock = new object();
        readonly object cleanupLock = new object();

        public MainForm(string[] args)
        {
            foreach (string a in args)
            {
                if (a == "--no-driver") noDriver = true;
                else if (a.StartsWith("--demo=")) demo = a.Substring(7);
                else if (a.StartsWith("--shot=")) shotPath = a.Substring(7);
                else if (a.StartsWith("--shot2=")) shot2Path = a.Substring(8);
                else if (a.StartsWith("--move=")) moveTo = a.Substring(7);
                else if (a == "--primary") onPrimary = true;
            }
            exePath = ResolveSenderPath();

            Text = "DualSlate";
            // FixedSingle, not FixedDialog: a dialog frame shows no icon, which left
            // the caption text jammed against the window's left edge.
            FormBorderStyle = FormBorderStyle.FixedSingle;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            MaximizeBox = false;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.Manual;
            BackColor = Ui.Bg;
            DoubleBuffered = true;
            tip = new ToolTip { AutoPopDelay = 30000, InitialDelay = 350, ReshowDelay = 100, ShowAlways = true };

            BuildUi();
            LoadSettings();
            UpdateEnabled();

            // Start on the monitor under the cursor, at that monitor's DPI.
            Point cur = Cursor.Position;
            if (onPrimary) { var pb = Screen.PrimaryScreen.Bounds; cur = new Point(pb.X + pb.Width / 2, pb.Y + pb.Height / 2); }
            int dpi = Dpi.ForPoint(cur);
            ApplyScale(dpi);
            var wa = Screen.FromPoint(cur).WorkingArea;
            Location = new Point(wa.X + Math.Max(0, (wa.Width - Width) / 2), wa.Y + Math.Max(0, (wa.Height - Height) / 2));
        }

        // ── Layout (all numbers are 96-dpi units) ────────────────────────
        T Add<T>(Control parent, T c, int x, int y, int w, int h, float px, string face = null, FontStyle style = FontStyle.Regular, bool fixedSize = false) where T : Control
        {
            parent.Controls.Add(c);
            items.Add(new Item { C = c, B = new Rectangle(x, y, w, h), FontPx = px, Face = face ?? Ui.Face, Style = style, Fixed = fixedSize });
            return c;
        }

        const float Body = 13.5f, Small = 12f;

        void BuildUi()
        {
            // Title, subtitle and section headings share one left edge (x 26).
            lblTitle = Add(this, new TightLabel { Text = "DualSlate", ForeColor = Ui.Text, BackColor = Ui.Bg, AutoSize = false }, 26, 18, 380, 34, 23f, Ui.Semi);
            lblSub = Add(this, new TightLabel { Text = "Extended Display - use your tablet as an extra screen", ForeColor = Ui.Muted, BackColor = Ui.Bg, AutoSize = false }, 26, 52, 380, 20, Small);
            pill = Add(this, new Pill { Text = "Starting up" }, 480, 22, 216, 30, 12.5f, Ui.Semi);

            // Left column: Connection + Quality.
            Section("Connection", 24, 80, 328);
            cardConn = Add(this, new Card(), 24, 102, 328, 134, Body);
            rbUsb = Add(cardConn, new FlatRadio { Text = "USB  (auto-detect)", Checked = true }, 16, 14, 270, 24, Body);
            rbWifi = Add(cardConn, new FlatRadio { Text = "Wi-Fi" }, 16, 44, 270, 24, Body);
            lblIpCap = Add(cardConn, new Label { Text = "IP (optional)", BackColor = Ui.Card, ForeColor = Ui.Text, AutoSize = false, TextAlign = ContentAlignment.MiddleLeft }, 41, 74, 90, 24, Body);
            txtIp = Add(cardConn, new TextBox { Enabled = false, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White }, 136, 75, 150, 24, Body);
            tip.SetToolTip(txtIp, Wrap("Optional. Enter the tablet's IP if auto-discovery fails (guest / AP-isolated networks). Leave blank to auto-find it on the LAN."));
            chkUdp = Add(cardConn, new FlatCheck { Text = "Low-latency UDP", Enabled = false }, 41, 102, 245, 24, Body);
            Info(cardConn, 102, 296, "Send video over UDP for lower latency on Wi-Fi. Helps on lossy / high-latency links; on a good 5 GHz link, plain TCP is usually smoother.", chkUdp);
            rbWifi.CheckedChanged += (s, e) => UpdateEnabled();

            Section("Quality", 24, 252, 328);
            // One preset instead of FPS / encoder / bitrate knobs; fine-grained
            // control stays on the CLI (--fps / --bitrate / --encoder).
            cardQual = Add(this, new Card(), 24, 274, 328, 134, Body);
            rbBestRes = Add(cardQual, new FlatRadio { Text = "Best resolution" }, 16, 14, 270, 24, Body);
            Info(cardQual, 14, 296, "Sharpest picture - native 2960x1848 at 60 fps with a higher 40 Mbps bitrate. Best for reading / documents / coding. Prefers USB or strong 5 GHz Wi-Fi.", rbBestRes);
            rbBalanced = Add(cardQual, new FlatRadio { Text = "Balanced  (recommended)", Checked = true }, 16, 55, 270, 24, Body);
            Info(cardQual, 55, 296, "Native 2960x1848 at 60 fps, 25 Mbps - the proven default. Right for almost everything.", rbBalanced);
            rbSmooth = Add(cardQual, new FlatRadio { Text = "Smooth motion  (120 fps)" }, 16, 96, 270, 24, Body);
            Info(cardQual, 96, 296, "Silkiest cursor / scrolling / gaming feel - 120 fps with the virtual display at 1920x1200 (the tablet upscales).", rbSmooth);

            // Right column: Options.
            Section("Options", 368, 80, 328);
            cardOpt = Add(this, new Card(), 368, 102, 328, 306, Body);
            chkTouch = Add(cardOpt, new FlatCheck { Text = "Touch input", Checked = true }, 16, 14, 270, 24, Body);
            Info(cardOpt, 14, 296, "Tablet touches control the PC - tap = click, drag = move / scroll, long-press = right-click. S Pen pressure & hover work too.", chkTouch);
            chkHevc = Add(cardOpt, new FlatCheck { Text = "HEVC / H.265" }, 16, 44, 270, 24, Body);
            Info(cardOpt, 44, 296, "H.265 - better compression, so motion (video playback, scrolling) looks cleaner at the same bitrate. Barely visible on a static desktop; tick it mainly for watching video. Needs tablet HEVC decode (the S9 Ultra has it).", chkHevc);
            chkHdr = Add(cardOpt, new FlatCheck { Text = "HDR" }, 16, 74, 270, 24, Body);
            Info(cardOpt, 74, 296, "Experimental - for HDR video content only. The normal SDR desktop looks washed out, so leave this OFF for general use.", chkHdr);
            chkAudio = Add(cardOpt, new FlatCheck { Text = "Desktop audio" }, 16, 104, 270, 24, Body);
            Info(cardOpt, 104, 296, "Play the PC's sound on the tablet over the same link (no extra driver needed).", chkAudio);
            chkMute = Add(cardOpt, new FlatCheck { Text = "Mute PC speakers", Enabled = false }, 41, 134, 245, 24, Body);
            Info(cardOpt, 134, 296, "Sound plays only on the tablet; the PC's own speakers stay silent while streaming, even if you press the volume keys, and go back to how you had them when you Stop. Needs Windows 10 version 2004 or newer.", chkMute);
            lblDelay = Add(cardOpt, new Label { Text = "A/V sync delay (ms)", BackColor = Ui.Card, ForeColor = Ui.Text, AutoSize = false, TextAlign = ContentAlignment.MiddleLeft, Enabled = false }, 41, 164, 150, 24, Body);
            // Right edge at 286 like the IP box; vertically centred on its label in ApplyScale.
            numDelay = Add(cardOpt, new NumericUpDown { Minimum = 20, Maximum = 500, Value = 40, Increment = 5, Enabled = false, BorderStyle = BorderStyle.FixedSingle, TextAlign = HorizontalAlignment.Center }, 210, 164, 76, 26, Body);
            Info(cardOpt, 164, 296, "Audio delay for lip-sync (ms). Higher = audio plays later; lower it if audio lags the video. ~40 matches the tablet's own video; ~20 for watching the laptop with the tablet as a speaker.", numDelay);
            chkAudio.CheckedChanged += (s, e) =>
            {
                // The i markers stay enabled: tooltips never show over disabled
                // controls, and the descriptions should be readable before enabling.
                if (!chkAudio.Checked) chkMute.Checked = false;
                UpdateEnabled();
            };
            chkEncrypt = Add(cardOpt, new FlatCheck { Text = "Encrypt" }, 16, 202, 270, 24, Body);
            Info(cardOpt, 202, 296, "Require a pairing code (shown below) on the tablet. Encrypts video, touch and audio with AES-256 - use it on untrusted Wi-Fi. The code is remembered on both sides, so you type it on the tablet only once; click 'new code' to rotate it.", chkEncrypt);
            chkEncrypt.CheckedChanged += OnEncryptToggled;

            lblCodeCap = Add(cardOpt, new Label { Text = "PAIRING CODE", BackColor = Ui.Card, ForeColor = Ui.Muted, AutoSize = false, Visible = false }, 41, 238, 150, 18, 11f, Ui.Semi);
            lblCode = Add(cardOpt, new Label { Text = "", BackColor = Ui.Card, ForeColor = Ui.Accent, AutoSize = false, Visible = false, TextAlign = ContentAlignment.MiddleLeft }, 41, 256, 170, 34, 24f, Ui.Mono, FontStyle.Bold);
            lnkNewCode = Add(cardOpt, new LinkLabel { Text = "new code", BackColor = Ui.Card, AutoSize = false, Visible = false, TextAlign = ContentAlignment.MiddleRight, LinkColor = Ui.Accent, ActiveLinkColor = Ui.AccentDown, LinkBehavior = LinkBehavior.HoverUnderline }, 214, 262, 72, 22, Small);
            lnkNewCode.Click += OnNewCode;
            tip.SetToolTip(lnkNewCode, Wrap("Generate a fresh pairing code (rotates the key). Enter the new code on the tablet on the next Start."));

            lblDetail = Add(this, new TightLabel { Text = "", Wraps = true, ForeColor = Ui.Muted, BackColor = Ui.Bg, AutoSize = false }, 26, 418, 670, 42, Body);
            btnMain = Add(this, new BigButton { Text = "Start" }, 24, 462, 672, 44, 16f, Ui.Semi);
            btnMain.Click += OnMainClick;
            AcceptButton = btnMain;

            FormClosing += OnFormClosingHandler;
        }

        void Section(string text, int x, int y, int w)
        {
            Add(this, new TightLabel { Text = text, ForeColor = Ui.Muted, BackColor = Ui.Bg, AutoSize = false }, x + 2, y, w, 20, 12.5f, Ui.Semi);
        }

        // The i marker at the right edge of a row; the tooltip is also on the
        // related controls so hovering the row works.
        void Info(Control parent, int y, int x, string text, params Control[] related)
        {
            var d = Add(parent, new InfoDot(), x, y + 3, 18, 18, 11f, Ui.Semi);
            string wrapped = Wrap(text);
            tip.SetToolTip(d, wrapped);
            foreach (var c in related) tip.SetToolTip(c, wrapped);
        }

        // WinForms tooltips don't word-wrap on their own; break every ~52 chars.
        static string Wrap(string text)
        {
            const int width = 52;
            var sb = new StringBuilder();
            int lineLen = 0;
            foreach (string word in text.Split(' '))
            {
                if (lineLen > 0 && lineLen + 1 + word.Length > width) { sb.Append("\r\n"); lineLen = 0; }
                else if (lineLen > 0) { sb.Append(' '); lineLen++; }
                sb.Append(word);
                lineLen += word.Length;
            }
            return sb.ToString();
        }

        // Re-apply every size and font from the 96-dpi base values.
        void ApplyScale(int dpi)
        {
            Ui.K = dpi / 96f;
            SuspendLayout();
            ClientSize = new Size(Ui.S(BaseW), Ui.S(BaseH));
            foreach (var it in items)
            {
                it.C.Font = Ui.Font(it.Face, it.FontPx, it.Style);
                it.C.Bounds = new Rectangle(Ui.S(it.B.X), Ui.S(it.B.Y), Ui.S(it.B.Width), Ui.S(it.B.Height));
            }
            ResumeLayout(true);
            // A NumericUpDown sizes its own height from the font; centre it on its label.
            numDelay.Top = lblDelay.Top + (lblDelay.Height - numDelay.Height) / 2;
            LayoutPill();
            Invalidate(true);
        }

        void LayoutPill()
        {
            int w = pill.PreferredWidth();
            int right = Ui.S(696);
            pill.Bounds = new Rectangle(right - w, Ui.S(22), w, Ui.S(30));
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            // Make sure the client area is exactly the scaled base size (the
            // non-client frame is measured once the handle exists).
            ClientSize = new Size(Ui.S(BaseW), Ui.S(BaseH));
        }

        const int WM_DPICHANGED = 0x02E0;
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_DPICHANGED)
            {
                int dpi = (int)((long)m.WParam & 0xFFFF);
                var r = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
                ApplyScale(dpi);
                SetBounds(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
                ClientSize = new Size(Ui.S(BaseW), Ui.S(BaseH));  // exact, whatever the suggested rect rounded to
                m.Result = IntPtr.Zero;
                return;
            }
            if (m.Msg == WM_DISPLAYCHANGE && state == AppState.Ready && !noDriver)
            {
                // Windows re-applies a saved layout on any display change (a monitor
                // plugged in or out, docking, waking up), which can switch the idle
                // virtual screen back on (measured: unplugging HDMI did). While idle,
                // switch it off again once the change settles. --cleanup is a no-op
                // when it is already off, so this can't loop.
                if (displayChangeTimer == null)
                {
                    displayChangeTimer = new System.Windows.Forms.Timer { Interval = 800 };
                    displayChangeTimer.Tick += (s, e) =>
                    {
                        displayChangeTimer.Stop();
                        if (state == AppState.Ready && !closing)
                            ThreadPool.QueueUserWorkItem(_ => RunCleanup(3000));
                    };
                }
                displayChangeTimer.Stop();
                displayChangeTimer.Start();
            }
            base.WndProc(ref m);
        }

        const int WM_DISPLAYCHANGE = 0x007E;
        System.Windows.Forms.Timer displayChangeTimer;

        // ── State / status presentation ──────────────────────────────────
        void Post(Action a)
        {
            try { if (IsHandleCreated && !IsDisposed) BeginInvoke(a); } catch { }
        }

        void SetPill(string text, Tone tone)
        {
            if (pill.Text != text) { pill.Text = text; LayoutPill(); }
            pill.Tone = tone;
        }

        void SetDetail(string text) { if (lblDetail.Text != text) lblDetail.Text = text; }

        void SetState(AppState s)
        {
            state = s;
            switch (s)
            {
                case AppState.Loading:
                    btnMain.Text = "Start"; btnMain.Danger = false; btnMain.Enabled = false; SetLocked(false); break;
                case AppState.Ready:
                    btnMain.Text = "Start"; btnMain.Danger = false; btnMain.Enabled = true; SetLocked(false); break;
                case AppState.Starting:
                    btnMain.Text = "Starting…"; btnMain.Danger = false; btnMain.Enabled = false; SetLocked(true); break;
                case AppState.Running:
                    btnMain.Text = "Stop"; btnMain.Danger = true; btnMain.Enabled = true; SetLocked(true); break;
                case AppState.Stopping:
                    btnMain.Text = "Stopping…"; btnMain.Danger = true; btnMain.Enabled = false; SetLocked(true); break;
                case AppState.Fault:
                    btnMain.Text = "Retry"; btnMain.Danger = false; btnMain.Enabled = true; SetLocked(false); break;
                case AppState.Closing:
                    btnMain.Enabled = false; break;
            }
            btnMain.Invalidate();
        }

        // Options apply when the sender starts, so they are locked while it runs.
        // Only the inputs are disabled (not their cards), so the pairing code stays
        // fully visible while streaming.
        void SetLocked(bool v) { locked = v; UpdateEnabled(); }

        void UpdateEnabled()
        {
            bool free = !locked;
            rbUsb.Enabled = rbWifi.Enabled = free;
            txtIp.Enabled = chkUdp.Enabled = lblIpCap.Enabled = free && rbWifi.Checked;
            rbBestRes.Enabled = rbBalanced.Enabled = rbSmooth.Enabled = free;
            chkTouch.Enabled = chkHevc.Enabled = chkHdr.Enabled = chkAudio.Enabled = chkEncrypt.Enabled = free;
            chkMute.Enabled = numDelay.Enabled = lblDelay.Enabled = free && chkAudio.Checked;
            lnkNewCode.Enabled = free;
        }

        // ── Driver lifecycle ─────────────────────────────────────────────
        void BeginLoad()
        {
            SetState(AppState.Loading);
            SetPill("Starting up", Tone.Busy);
            SetDetail("Loading the virtual display driver…");
            if (noDriver) { Post(() => OnLoaded(Vdd.Result.Ok, "")); return; }
            ThreadPool.QueueUserWorkItem(_ =>
            {
                string detail;
                Vdd.Result r;
                lock (driverLock)
                {
                    if (closing) return;
                    r = Vdd.Set(true, out detail);
                }
                if (r == Vdd.Result.Ok) RunCleanup(3000);
                Post(() => OnLoaded(r, detail));
            });
        }

        void OnLoaded(Vdd.Result r, string detail)
        {
            if (closing) return;
            if (r == Vdd.Result.NotInstalled &&
                File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "driver-pending.flag")))
            {
                // install-vdd.ps1: Windows must restart before the driver can attach; it
                // finishes by itself at the next start.
                SetState(AppState.Fault);
                SetPill("Restart needed", Tone.Warn);
                SetDetail("Restart Windows once to finish installing the virtual display driver. It completes by itself during the restart; then open DualSlate again.");
                return;
            }
            if (r == Vdd.Result.NotInstalled &&
                File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "driver-failed.flag")))
            {
                SetState(AppState.Fault);
                SetPill("Driver failed", Tone.Bad);
                SetDetail("The virtual display driver could not be installed on this PC. Details: install-vdd.log in " +
                          AppDomain.CurrentDomain.BaseDirectory + " - please attach it to a GitHub issue.");
                return;
            }
            if (r == Vdd.Result.NotInstalled)
            {
                SetState(AppState.Fault);
                SetPill("Driver missing", Tone.Bad);
                SetDetail("The virtual display driver isn't installed. Re-run the DualSlate installer (DualSlateSetup.exe) to repair it, then click Retry.");
                return;
            }
            if (r == Vdd.Result.Failed)
            {
                SetState(AppState.Fault);
                SetPill("Driver error", Tone.Bad);
                SetDetail("Couldn't load the virtual display driver: " + detail + ". Re-run the DualSlate installer to repair it, then click Retry.");
                return;
            }
            if (!noDriver && !File.Exists(exePath))
            {
                SetState(AppState.Fault);
                SetPill("Sender missing", Tone.Bad);
                SetDetail("ExtendedDisplaySender.exe was not found at " + exePath + ". Re-run the DualSlate installer, then click Retry.");
                return;
            }
            SetState(AppState.Ready);
            SetPill("Ready", Tone.Neutral);
            SetDetail("Connect the tablet, then press Start.");
            if (demo != null) RunDemo();
        }

        // ── Sender helpers (blocking: worker threads only) ───────────────
        // "--cleanup": virtual screen off, PC speakers restored. Fast (< 1 s).
        void RunCleanup(int timeoutMs)
        {
            if (noDriver || !File.Exists(exePath)) return;
            lock (cleanupLock)
            {
                try
                {
                    var psi = new ProcessStartInfo(exePath, "--cleanup") { UseShellExecute = false, CreateNoWindow = true };
                    using (var p = Process.Start(psi))
                    {
                        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
                    }
                }
                catch { }
                dirty = false;
            }
        }

        // Graceful stop via the sender's named event; Kill only as a last resort.
        static void StopSenderBlocking(Process p, int budgetMs)
        {
            if (p == null) return;
            try { if (p.HasExited) return; } catch { return; }
            var sw = Stopwatch.StartNew();
            string name = "Local\\ExtendedDisplaySender-Stop-" + p.Id;
            EventWaitHandle ev = null;
            // The sender creates the event just after launch; allow for a Stop
            // pressed right after Start.
            while (ev == null && sw.ElapsedMilliseconds < 1500)
            {
                try { ev = EventWaitHandle.OpenExisting(name, EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize); }
                catch (WaitHandleCannotBeOpenedException) { }
                catch (UnauthorizedAccessException) { break; }
                if (ev == null) { try { if (p.WaitForExit(40)) return; } catch { return; } }
            }
            if (ev != null)
            {
                try { ev.Set(); } catch { }
                ev.Close();
                try { if (p.WaitForExit(Math.Max(200, budgetMs - (int)sw.ElapsedMilliseconds))) return; } catch { return; }
            }
            try { p.Kill(); p.WaitForExit(1500); } catch { }
        }

        // ── Start / Stop ─────────────────────────────────────────────────
        void OnMainClick(object s, EventArgs e)
        {
            if (state == AppState.Ready) StartStreaming();
            else if (state == AppState.Running) StopStreaming();
            else if (state == AppState.Fault) BeginLoad();
        }

        void StartStreaming()
        {
            if (state != AppState.Ready) return;
            SaveSettings();
            if (chkEncrypt.Checked && pairCode.Length == 0)
            {
                pairCode = GenerateCode(); SaveCode(pairCode);
                lblCode.Text = pairCode;
            }

            // Build the flags first: they read control states that locking changes.
            var sb = new StringBuilder();
            if (rbWifi.Checked)
            {
                string ip = txtIp.Text.Trim();
                // A manual IP connects directly (skips discovery broadcast); empty
                // falls back to auto-discovery on the LAN.
                if (ip.Length > 0) sb.Append(" --host " + ip);
                else sb.Append(" --wifi");
            }
            // Encryption works on both transports, so honour the user's UDP choice.
            if (chkUdp.Checked && chkUdp.Enabled) sb.Append(" --udp");
            if (chkHdr.Checked) sb.Append(" --hdr");
            else if (chkHevc.Checked) sb.Append(" --hevc");
            if (!chkTouch.Checked) sb.Append(" --no-touch");
            if (chkAudio.Checked) sb.Append(" --audio");
            if (chkAudio.Checked) sb.Append(" --audio-delay-ms " + (int)numDelay.Value);
            if (chkMute.Checked && chkMute.Enabled) sb.Append(" --mute-local");
            // Quality preset -> flags. Balanced = the sender's defaults.
            if (rbBestRes.Checked) sb.Append(" --bitrate 40000");
            if (rbSmooth.Checked) sb.Append(" --fps 120");

            liveFps = ""; liveState = "Starting"; liveNote = "";
            liveMode = rbWifi.Checked ? (chkUdp.Checked ? "Wi-Fi UDP" : "Wi-Fi") : "USB";
            string args = sb.ToString();
            string key = chkEncrypt.Checked && pairCode.Length > 0 ? pairCode : null;

            SetState(AppState.Starting);
            SetPill("Starting", Tone.Busy);
            SetDetail("Starting…  (" + liveMode + ")");

            ThreadPool.QueueUserWorkItem(_ =>
            {
                Process p = null; string err = null;
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = exePath, Arguments = args, UseShellExecute = false, CreateNoWindow = true,
                        RedirectStandardOutput = true, RedirectStandardError = true,
                    };
                    // Pass the pairing code out-of-band (env, not argv) so it never
                    // shows in a process listing.
                    if (key != null) psi.EnvironmentVariables["EXTDISPLAY_KEY"] = key;
                    p = new Process { StartInfo = psi, EnableRaisingEvents = true };
                    p.OutputDataReceived += (s2, ev) => { if (ev.Data != null) { string l = ev.Data; var pp = p; Post(() => { if (pp == sender) OnSenderLine(l); }); } };
                    p.ErrorDataReceived += (s2, ev) => { if (ev.Data != null) { string l = ev.Data; var pp = p; Post(() => { if (pp == sender) OnSenderLine(l); }); } };
                    p.Exited += (s2, ev) => { var pp = p; Post(() => OnSenderExited(pp)); };
                    dirty = true;
                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                }
                catch (Exception ex) { err = ex.Message; p = null; }
                Post(() => OnSpawned(p, err));
            });
        }

        void OnSpawned(Process p, string err)
        {
            if (closing) return;
            if (p == null)
            {
                SetState(AppState.Ready);
                SetPill("Couldn't start", Tone.Bad);
                SetDetail("Failed: " + err);
                return;
            }
            sender = p;
            SetState(AppState.Running);
            ShowLive();
            // Exited may have fired before this ran (instant crash).
            try { if (p.HasExited) OnSenderExited(p); } catch { }
        }

        void StopStreaming()
        {
            if (state != AppState.Running) return;
            var p = sender;
            SetState(AppState.Stopping);
            SetPill("Stopping", Tone.Neutral);
            SetDetail("Stopping…");
            ThreadPool.QueueUserWorkItem(_ =>
            {
                StopSenderBlocking(p, 4000);
                RunCleanup(3000);
                Post(() => OnStopped("Stopped. Virtual screen off."));
            });
        }

        // The sender quit by itself (crash, tablet unplugged and gave up, ...).
        void OnSenderExited(Process p)
        {
            if (p != sender || state != AppState.Running || closing) return;
            int code = 0;
            try { code = p.ExitCode; } catch { }
            SetState(AppState.Stopping);
            SetPill("Stopping", Tone.Neutral);
            SetDetail("Sender exited. Cleaning up…");
            ThreadPool.QueueUserWorkItem(_ =>
            {
                RunCleanup(3000);
                Post(() => OnStopped(code == 0 ? "Sender exited. Virtual screen off." : "Sender exited unexpectedly (code " + code + "). Virtual screen off."));
            });
        }

        void OnStopped(string detail)
        {
            if (closing) return;
            var p = sender; sender = null;
            try { if (p != null) p.Dispose(); } catch { }
            liveState = ""; liveFps = "";
            SetState(AppState.Ready);
            SetPill("Ready", Tone.Neutral);
            SetDetail(detail);
        }

        // Parse a line from the sender / ffmpeg into a live status.
        void OnSenderLine(string line)
        {
            if (state != AppState.Running) return;
            var m = Regex.Match(line, @"fps=\s*([\d.]+)");
            if (m.Success && m.Groups[1].Value != "0" && m.Groups[1].Value != "0.0")
                liveFps = m.Groups[1].Value;

            if (line.IndexOf("muting this PC's speakers also silences", StringComparison.OrdinalIgnoreCase) >= 0)
                liveNote = "PC speakers can't be muted on this PC (it would silence the tablet)";
            // The tablet holds a different pairing code (or none): the sender keeps
            // retrying, and the tablet is asking for the code shown in this window.
            if (Regex.IsMatch(line, "Pairing code mismatch", RegexOptions.IgnoreCase))
                { liveState = "Pairing"; liveFps = ""; }
            else if (Regex.IsMatch(line, "accepted the pairing code", RegexOptions.IgnoreCase))
                liveState = "Streaming";
            else if (liveState == "Pairing")
                { liveFps = ""; }  // retries print "Streaming ... with"; stay on the pairing hint
            else if (Regex.IsMatch(line, "Virtual screen off", RegexOptions.IgnoreCase))
                { liveState = "Waiting"; liveFps = ""; }
            else if (Regex.IsMatch(line, "Virtual screen on", RegexOptions.IgnoreCase))
                liveState = "Streaming";
            else if (Regex.IsMatch(line, "Reconnecting|Stream ended", RegexOptions.IgnoreCase))
                { liveState = "Reconnecting"; liveFps = ""; }
            else if (Regex.IsMatch(line, "Searching|No tablet found", RegexOptions.IgnoreCase))
                liveState = "Searching";
            else if (Regex.IsMatch(line, @"Streaming .*(over|with)|Tablet found|Tablet connected|Extended display:", RegexOptions.IgnoreCase))
                liveState = "Streaming";
            ShowLive();
        }

        void ShowLive()
        {
            string note = liveNote.Length > 0 ? "  •  " + liveNote : "";
            switch (liveState)
            {
                case "Streaming":
                    SetPill("Streaming", Tone.Good);
                    SetDetail(liveMode + (liveFps.Length > 0 ? "  •  " + liveFps + " fps" : "") + note); break;
                case "Pairing":
                    SetPill("Pairing", Tone.Warn);
                    SetDetail("The tablet needs the pairing code shown under Options. Type it on the tablet."); break;
                case "Reconnecting":
                    SetPill("Reconnecting", Tone.Warn); SetDetail("Reconnecting…  (" + liveMode + ")" + note); break;
                case "Searching":
                    SetPill("Searching", Tone.Warn); SetDetail("Searching for the tablet…  (" + liveMode + ")" + note); break;
                case "Waiting":
                    SetPill("Waiting for the tablet", Tone.Warn); SetDetail("The virtual screen is off until the tablet connects.  (" + liveMode + ")" + note); break;
                default:
                    SetPill("Starting", Tone.Busy); SetDetail("Starting…  (" + liveMode + ")"); break;
            }
        }

        // ── Close: hide at once, finish in the background, capped ────────
        void OnFormClosingHandler(object s, FormClosingEventArgs e)
        {
            if (closing) { e.Cancel = true; return; }
            closing = true;
            e.Cancel = true;
            SaveSettings();
            Hide();
            var p = sender;
            bool needDriver = !noDriver;
            var t = new Thread(() =>
            {
                var sw = Stopwatch.StartNew();
                try
                {
                    if (!noDriver)
                    {
                        StopSenderBlocking(p, 4000);
                        if (dirty) RunCleanup((int)Math.Max(500, 5500 - sw.ElapsedMilliseconds));
                        lock (driverLock) { string d; Vdd.Set(false, out d); }
                    }
                }
                catch { }
                Environment.Exit(0);
            }) { IsBackground = false };
            t.Start();
            // Watchdog: never hang around longer than ~6 s.
            var wd = new Thread(() => { Thread.Sleep(6000); Environment.Exit(0); }) { IsBackground = true };
            wd.Start();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            BeginLoad();
            if (shotPath != null) BeginShots();
        }

        string ResolveSenderPath()
        {
            // Packaged: the sender sits beside this launcher. Dev tree: the launcher
            // may run from windows-sender\launcher\ or windows-sender\build\Release\.
            string bd = AppDomain.CurrentDomain.BaseDirectory;
            string[] candidates =
            {
                Path.Combine(bd, "ExtendedDisplaySender.exe"),
                Path.Combine(bd, @"..\build\Release\ExtendedDisplaySender.exe"),
                Path.Combine(bd, @"..\..\build\Release\ExtendedDisplaySender.exe"),
            };
            foreach (var c in candidates)
            {
                string full = Path.GetFullPath(c);
                if (File.Exists(full)) return full;
            }
            return Path.GetFullPath(candidates[0]);
        }

        // ── Pairing code ─────────────────────────────────────────────────
        // Ticking Encrypt shows the pairing code. The code persists across launches
        // (the tablet stores the derived key), so it is typed on the tablet once;
        // "new code" rotates it.
        void OnEncryptToggled(object s, EventArgs e)
        {
            bool on = chkEncrypt.Checked;
            if (on)
            {
                if (pairCode.Length == 0) pairCode = LoadCode();
                if (pairCode.Length == 0) { pairCode = GenerateCode(); SaveCode(pairCode); }
                lblCode.Text = pairCode;
            }
            lblCodeCap.Visible = lblCode.Visible = lnkNewCode.Visible = on;
        }

        void OnNewCode(object s, EventArgs e)
        {
            pairCode = GenerateCode();
            SaveCode(pairCode);
            lblCode.Text = pairCode;
            SetDetail("New code. Enter it on the tablet on the next Start.");
        }

        static string CodePath()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ExtendedDisplay");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "pairing.code");
        }

        static string LoadCode()
        {
            try
            {
                if (File.Exists(CodePath()))
                {
                    string code = File.ReadAllText(CodePath()).Trim();
                    if (code.Length == 8) return code;
                }
            }
            catch { }
            return "";
        }

        static void SaveCode(string code)
        {
            try { File.WriteAllText(CodePath(), code); } catch { }
        }

        // ── Remembered settings (unchanged format) ───────────────────────
        static string SettingsPath()
        {
            return Path.Combine(Path.GetDirectoryName(CodePath()), "settings.ini");
        }

        void LoadSettings()
        {
            var v = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(SettingsPath()))
                    foreach (string raw in File.ReadAllLines(SettingsPath()))
                    {
                        int eq = raw.IndexOf('=');
                        if (eq > 0) v[raw.Substring(0, eq).Trim()] = raw.Substring(eq + 1).Trim();
                    }
            }
            catch { return; }
            string s;
            Func<string, bool, bool> flag = (k, d) => v.TryGetValue(k, out s) ? s == "1" : d;
            if (v.TryGetValue("connection", out s)) { rbWifi.Checked = s == "wifi"; rbUsb.Checked = s != "wifi"; }
            if (v.TryGetValue("ip", out s)) txtIp.Text = s;
            chkUdp.Checked = flag("udp", chkUdp.Checked);
            if (v.TryGetValue("quality", out s))
            {
                rbBestRes.Checked = s == "best";
                rbSmooth.Checked = s == "smooth";
                rbBalanced.Checked = s != "best" && s != "smooth";
            }
            chkTouch.Checked = flag("touch", chkTouch.Checked);
            chkHevc.Checked = flag("hevc", chkHevc.Checked);
            chkHdr.Checked = flag("hdr", chkHdr.Checked);
            chkAudio.Checked = flag("audio", chkAudio.Checked);
            chkMute.Checked = chkAudio.Checked && flag("mute", chkMute.Checked);
            int delay;
            if (v.TryGetValue("audio_delay_ms", out s) && int.TryParse(s, out delay))
                numDelay.Value = Math.Max(numDelay.Minimum, Math.Min(numDelay.Maximum, delay));
            chkEncrypt.Checked = flag("encrypt", chkEncrypt.Checked);  // shows the saved code
        }

        void SaveSettings()
        {
            if (noDriver && demo != null) return;  // screenshots must not rewrite the user's settings
            try
            {
                File.WriteAllLines(SettingsPath(), new[]
                {
                    "connection=" + (rbWifi.Checked ? "wifi" : "usb"),
                    "ip=" + txtIp.Text.Trim(),
                    "udp=" + (chkUdp.Checked ? "1" : "0"),
                    "quality=" + (rbBestRes.Checked ? "best" : rbSmooth.Checked ? "smooth" : "balanced"),
                    "touch=" + (chkTouch.Checked ? "1" : "0"),
                    "hevc=" + (chkHevc.Checked ? "1" : "0"),
                    "hdr=" + (chkHdr.Checked ? "1" : "0"),
                    "audio=" + (chkAudio.Checked ? "1" : "0"),
                    "mute=" + (chkMute.Checked ? "1" : "0"),
                    "audio_delay_ms=" + (int)numDelay.Value,
                    "encrypt=" + (chkEncrypt.Checked ? "1" : "0"),
                });
            }
            catch { }
        }

        // 8-char code from an unambiguous alphabet (no I/O/0/1), crypto-random.
        static string GenerateCode()
        {
            const string abc = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
            var bytes = new byte[8];
            using (var rng = System.Security.Cryptography.RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            var chars = new char[8];
            for (int i = 0; i < 8; i++) chars[i] = abc[bytes[i] % abc.Length];
            return new string(chars);
        }

        // ── Verification-only: simulated states and screenshots ──────────
        void RunDemo()
        {
            if (!noDriver) return;
            switch (demo)
            {
                case "streaming":
                case "waiting":
                case "pairing":
                    liveMode = "Wi-Fi UDP"; liveFps = ""; liveNote = "";
                    SetState(AppState.Running);
                    if (demo == "streaming") { liveState = "Streaming"; liveFps = "60"; }
                    else if (demo == "waiting") liveState = "Waiting";
                    else { liveState = "Pairing"; chkEncrypt.Checked = true; }
                    ShowLive();
                    break;
                case "stopping":
                    SetState(AppState.Stopping); SetPill("Stopping", Tone.Neutral); SetDetail("Stopping…"); break;
                case "fault":
                    OnLoaded(Vdd.Result.NotInstalled, ""); break;
                case "encrypt":
                    chkEncrypt.Checked = true; break;
            }
        }

        void BeginShots()
        {
            var t = new System.Windows.Forms.Timer { Interval = 900 };
            t.Tick += (s, e) =>
            {
                t.Stop();
                Shot(shotPath);
                if (moveTo != null)
                {
                    // Move to the other monitor (a plain window move; no display change).
                    Screen other = null;
                    foreach (var sc in Screen.AllScreens) if (!sc.Primary) other = sc;
                    if (other != null)
                    {
                        var b = other.Bounds;
                        Location = new Point(b.X + 60, b.Y + 40);
                        var t2 = new System.Windows.Forms.Timer { Interval = 1200 };
                        t2.Tick += (s2, e2) => { t2.Stop(); Shot(shot2Path ?? shotPath + ".moved.png"); Finish(); };
                        t2.Start();
                        return;
                    }
                }
                Finish();
            };
            t.Start();
        }

        void Finish() { Environment.Exit(0); }

        void Shot(string path)
        {
            TopMost = true; Activate();
            Application.DoEvents();
            var info = new StringBuilder("shot " + path + ": K=" + Ui.K + " client=" + ClientSize + " bounds=" + Bounds + " windowDpi=" + Dpi.ForPoint(new Point(Bounds.X + Bounds.Width / 2, Bounds.Y + Bounds.Height / 2)));
            foreach (var sc in Screen.AllScreens) info.Append(" | " + sc.DeviceName + " " + sc.Bounds + " dpi=" + Dpi.ForPoint(new Point(sc.Bounds.X + 10, sc.Bounds.Y + 10)));
            try { File.AppendAllText((shotPath ?? "info") + ".txt", info + Environment.NewLine); } catch { }
            Rectangle r = Bounds;
            using (var bmp = new Bitmap(r.Width, r.Height))
            {
                using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size);
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            TopMost = false;
        }

        // ── Entry ────────────────────────────────────────────────────────
        [STAThread]
        static void Main(string[] args)
        {
            bool test = false;
            foreach (string a in args) if (a == "--no-driver") test = true;
            if (args.Length > 0 && args[0].StartsWith("--probe-driver="))
            {
                // Read-only probe used for verification: where is the driver and what state?
                var sw = Stopwatch.StartNew();
                Vdd.Info i; bool f = Vdd.Find(out i);
                File.WriteAllText(args[0].Substring(15), "found=" + f + (f ? " id=" + i.InstanceId + " started=" + i.Started + " problem=" + i.Problem : "") + " ms=" + sw.Elapsed.TotalMilliseconds);
                return;
            }
            bool created;
            using (var mutex = new Mutex(true, "Local\\ExtendedDisplayLauncher", out created))
            {
                if (!created && !test)
                {
                    MessageBox.Show("DualSlate is already running.", "DualSlate", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm(args));
            }
        }
    }
}
