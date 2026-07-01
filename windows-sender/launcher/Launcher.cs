// Extended Display launcher — a small WinForms settings dialog that configures
// and starts ExtendedDisplaySender.exe, and manages the virtual display driver
// (enable on Start, disable on Stop so no ghost monitor lingers).
//
// Compiled to a real .exe with an elevation manifest, so it gets a single clean
// UAC prompt, proper DPI scaling, and reliable foreground — none of the console
// flashing / encoding fragility of the PowerShell version.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ExtendedDisplay
{
    static class Native
    {
        [DllImport("user32.dll")]
        public static extern int SetDisplayConfig(uint n, IntPtr p, uint m, IntPtr q, uint flags);

        public const uint SDC_APPLY = 0x80;
        public const uint SDC_TOPOLOGY_INTERNAL = 0x01;
        public const uint SDC_TOPOLOGY_EXTEND = 0x04;

    }

    public class MainForm : Form
    {
        const string VddInstanceId = @"ROOT\DISPLAY\0000";

        RadioButton rbUsb, rbWifi;
        CheckBox chkUdp, chkTouch, chkHevc, chkHdr, chkEncrypt;
        ComboBox cmbFps, cmbEnc;
        TextBox txtBit, txtIp;
        Button btnStart, btnStop;
        Label lblStatus, lblCode;
        string pairCode = "";
        Process sender;
        string exePath;
        string liveFps = "";
        string liveState = "";
        string liveMode = "";

        public MainForm()
        {
            exePath = ResolveSenderPath();

            Text = "Extended Display";
            ClientSize = new Size(380, 470);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9.5f);

            // ── Connection ────────────────────────────────────────────────
            var grpConn = new GroupBox { Text = "Connection", Location = new Point(12, 10), Size = new Size(356, 96) };
            rbUsb = new RadioButton { Text = "USB  (auto-detect via adb)", Location = new Point(12, 22), AutoSize = true, Checked = true };
            rbWifi = new RadioButton { Text = "Wi-Fi", Location = new Point(12, 46), AutoSize = true };
            // Manual tablet IP for networks that block the discovery broadcast
            // (AP isolation, guest networks). Empty = auto-discover on the LAN.
            var lblIp = new Label { Text = "IP (optional):", Location = new Point(78, 48), AutoSize = true };
            txtIp = new TextBox { Location = new Point(162, 45), Width = 120, Enabled = false, Text = "" };
            chkUdp = new CheckBox { Text = "Low-latency UDP  (Wi-Fi only)", Location = new Point(30, 70), AutoSize = true, Enabled = false };
            rbWifi.CheckedChanged += (s, e) => { chkUdp.Enabled = rbWifi.Checked; txtIp.Enabled = rbWifi.Checked; };
            grpConn.Controls.AddRange(new Control[] { rbUsb, rbWifi, lblIp, txtIp, chkUdp });

            // ── Video ─────────────────────────────────────────────────────
            var grpVid = new GroupBox { Text = "Video", Location = new Point(12, 114), Size = new Size(356, 100) };
            var lblFps = new Label { Text = "FPS:", Location = new Point(12, 26), AutoSize = true };
            cmbFps = new ComboBox { Location = new Point(70, 23), Width = 70, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbFps.Items.AddRange(new object[] { "60", "120" }); cmbFps.SelectedIndex = 0;
            var lblEnc = new Label { Text = "Encoder:", Location = new Point(160, 26), AutoSize = true };
            cmbEnc = new ComboBox { Location = new Point(225, 23), Width = 118, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbEnc.Items.AddRange(new object[] { "Auto", "nvenc", "qsv", "mf", "amf", "x264" }); cmbEnc.SelectedIndex = 0;
            var lblBit = new Label { Text = "Bitrate (Kbps):", Location = new Point(12, 62), AutoSize = true };
            txtBit = new TextBox { Text = "25000", Location = new Point(115, 59), Width = 90 };
            grpVid.Controls.AddRange(new Control[] { lblFps, cmbFps, lblEnc, cmbEnc, lblBit, txtBit });

            // ── Options ───────────────────────────────────────────────────
            var grpOpt = new GroupBox { Text = "Options", Location = new Point(12, 222), Size = new Size(356, 130) };
            chkTouch = new CheckBox { Text = "Touch input  (tablet controls PC)", Location = new Point(12, 22), AutoSize = true, Checked = true };
            chkHevc = new CheckBox { Text = "HEVC / H.265  (better at high FPS)", Location = new Point(12, 48), AutoSize = true };
            chkHdr = new CheckBox { Text = "HDR  (experimental - HDR video only; desktop looks washed)", Location = new Point(12, 74), AutoSize = true };
            chkEncrypt = new CheckBox { Text = "Encrypt  (require pairing code on the tablet)", Location = new Point(12, 100), AutoSize = true };
            chkEncrypt.CheckedChanged += OnEncryptToggled;
            grpOpt.Controls.AddRange(new Control[] { chkTouch, chkHevc, chkHdr, chkEncrypt });

            // ── Pairing code + status + buttons ───────────────────────────
            lblCode = new Label { Text = "", Location = new Point(14, 360), Size = new Size(356, 22), ForeColor = Color.MediumBlue, Font = new Font("Consolas", 11f, FontStyle.Bold) };
            lblStatus = new Label { Text = "Ready.", Location = new Point(14, 384), Size = new Size(356, 20), ForeColor = Color.DimGray };
            btnStart = new Button { Text = "Start Streaming", Location = new Point(12, 408), Size = new Size(170, 36), BackColor = Color.FromArgb(0, 120, 212), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
            btnStop = new Button { Text = "Stop", Location = new Point(198, 408), Size = new Size(170, 36), Enabled = false };
            btnStart.Click += OnStart;
            btnStop.Click += OnStop;

            Controls.AddRange(new Control[] { grpConn, grpVid, grpOpt, lblCode, lblStatus, btnStart, btnStop });

            FormClosing += (s, e) => { StopSender(); DisableVdd(); };

            if (!File.Exists(exePath))
                SetStatus("WARNING: sender not found at " + exePath, Color.Firebrick);
        }

        string ResolveSenderPath()
        {
            // The sender ships in the same folder as this launcher (the installer
            // lays them side by side). Fall back to the dev build tree so the
            // launcher also runs straight from a checkout.
            string here = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ExtendedDisplaySender.exe");
            if (File.Exists(here)) return here;
            string dev = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                @"..\..\build\Release\ExtendedDisplaySender.exe");
            return Path.GetFullPath(dev);
        }

        void SetStatus(string msg, Color color)
        {
            lblStatus.Text = msg;
            lblStatus.ForeColor = color;
            lblStatus.Refresh();
        }

        void RunHidden(string file, string args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = file,
                Arguments = args,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            try { using (var p = Process.Start(psi)) { p.WaitForExit(15000); } } catch { }
        }

        void EnableVdd()
        {
            RunHidden("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Command \"Enable-PnpDevice -InstanceId '" + VddInstanceId + "' -Confirm:$false -EA SilentlyContinue\"");
            System.Threading.Thread.Sleep(2000);
            Native.SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, Native.SDC_APPLY | Native.SDC_TOPOLOGY_EXTEND);
        }

        // Disable ONLY the VDD device. Windows removes its extended area from the
        // desktop automatically; real monitors are untouched (unlike a topology
        // change to INTERNAL, which would also collapse real external displays).
        void DisableVddDevice()
        {
            RunHidden("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Command \"Disable-PnpDevice -InstanceId '" + VddInstanceId + "' -Confirm:$false -EA SilentlyContinue\"");
        }

        void DisableVdd()
        {
            // Device-only disable removes just the VDD; real external monitors are
            // untouched. (A SDC_TOPOLOGY_INTERNAL collapse would force the laptop
            // panel and drop any real second monitor.)
            DisableVddDevice();
        }

        // On open, clear any leftover virtual display from a previous crash or
        // force-kill (which skip the normal Stop cleanup). Device-only, so it
        // never disturbs real monitors. Start is disabled until this finishes to
        // avoid racing an enable against the disable.
        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            btnStart.Enabled = false;
            SetStatus("Checking for a leftover virtual display...", Color.DimGray);
            var worker = new System.ComponentModel.BackgroundWorker();
            worker.DoWork += (s, ev) => { try { DisableVddDevice(); } catch { } };
            worker.RunWorkerCompleted += (s, ev) =>
            {
                if (!btnStop.Enabled) { btnStart.Enabled = true; SetStatus("Ready.", Color.DimGray); }
            };
            worker.RunWorkerAsync();
        }

        // Toggling encryption mints a fresh pairing code and shows it. The user
        // types it into the tablet once; both derive the same key.
        void OnEncryptToggled(object s, EventArgs e)
        {
            if (chkEncrypt.Checked)
            {
                pairCode = GenerateCode();
                lblCode.Text = "Pairing code:  " + pairCode + "   → type it on the tablet";
            }
            else { pairCode = ""; lblCode.Text = ""; }
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

        void OnStart(object src, EventArgs e)
        {
            if (!File.Exists(exePath)) { SetStatus("Sender exe not found.", Color.Firebrick); return; }
            if (chkEncrypt.Checked && pairCode.Length == 0) pairCode = GenerateCode();

            SetStatus("Enabling virtual display...", Color.DimGray);
            btnStart.Enabled = false;
            EnableVdd();

            var sb = new System.Text.StringBuilder();
            if (rbWifi.Checked)
            {
                string ip = txtIp.Text.Trim();
                // A manual IP connects directly (skips discovery broadcast); empty
                // falls back to auto-discovery on the LAN.
                if (ip.Length > 0) sb.Append(" --host " + ip);
                else sb.Append(" --wifi");
            }
            // Encrypted video rides the UDP path (that's where the sender routes and
            // encrypts NALs), so force UDP when encrypting over Wi-Fi.
            if ((chkUdp.Checked && chkUdp.Enabled) || (chkEncrypt.Checked && rbWifi.Checked))
                sb.Append(" --udp");
            if (chkHdr.Checked) sb.Append(" --hdr");
            else if (chkHevc.Checked) sb.Append(" --hevc");
            if (!chkTouch.Checked) sb.Append(" --no-touch");
            if (cmbEnc.SelectedIndex > 0) sb.Append(" --encoder " + cmbEnc.SelectedItem);
            if ((string)cmbFps.SelectedItem != "60") sb.Append(" --fps " + cmbFps.SelectedItem);
            string bit = txtBit.Text.Trim();
            if (bit.Length > 0 && bit != "25000") sb.Append(" --bitrate " + bit);

            try
            {
                liveFps = ""; liveState = "Starting";
                liveMode = rbWifi.Checked ? (chkUdp.Checked ? "Wi-Fi UDP" : "Wi-Fi") : "USB";
                var psi = new ProcessStartInfo
                {
                    FileName = exePath,
                    Arguments = sb.ToString(),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                // Pass the pairing code out-of-band (env, not argv) so it never shows
                // in a process listing. The sender derives the key and encrypts.
                if (chkEncrypt.Checked && pairCode.Length > 0)
                    psi.EnvironmentVariables["EXTDISPLAY_KEY"] = pairCode;
                sender = Process.Start(psi);
                sender.EnableRaisingEvents = true;
                // The sender's own messages (stdout) and ffmpeg's -stats (stderr)
                // both flow here; we parse them for a live status line.
                sender.OutputDataReceived += (s2, ev) => { if (ev.Data != null) OnSenderLine(ev.Data); };
                sender.ErrorDataReceived  += (s2, ev) => { if (ev.Data != null) OnSenderLine(ev.Data); };
                sender.BeginOutputReadLine();
                sender.BeginErrorReadLine();
                sender.Exited += (s2, e2) => BeginInvoke((Action)(() =>
                {
                    if (btnStop.Enabled) { SetStatus("Sender exited.", Color.DimGray); btnStart.Enabled = true; btnStop.Enabled = false; }
                }));
                SetStatus("Starting…  (" + liveMode + ")", Color.Green);
                btnStop.Enabled = true;
            }
            catch (Exception ex)
            {
                SetStatus("Failed: " + ex.Message, Color.Firebrick);
                btnStart.Enabled = true;
                DisableVdd();
            }
        }

        // Parse a line from the sender / ffmpeg into a live status. ffmpeg's -stats
        // gives "fps=NN"; the sender's own messages give the connection state.
        void OnSenderLine(string line)
        {
            var m = Regex.Match(line, @"fps=\s*([\d.]+)");
            if (m.Success && m.Groups[1].Value != "0" && m.Groups[1].Value != "0.0")
                liveFps = m.Groups[1].Value;

            if (Regex.IsMatch(line, "Reconnecting|Stream ended", RegexOptions.IgnoreCase))
                { liveState = "Reconnecting"; liveFps = ""; }
            else if (Regex.IsMatch(line, "Searching|No tablet found", RegexOptions.IgnoreCase))
                liveState = "Searching";
            else if (Regex.IsMatch(line, @"Streaming .*(over|with)|Tablet found|Tablet connected|Extended display:", RegexOptions.IgnoreCase))
                liveState = "Streaming";

            string text;
            Color color;
            switch (liveState)
            {
                case "Streaming":
                    text = "Streaming  •  " + liveMode + (liveFps.Length > 0 ? "  •  " + liveFps + " fps" : "");
                    color = Color.Green; break;
                case "Reconnecting":
                    text = "Reconnecting…  (" + liveMode + ")"; color = Color.DarkOrange; break;
                case "Searching":
                    text = "Searching for tablet…  (" + liveMode + ")"; color = Color.DarkOrange; break;
                default:
                    text = "Starting…  (" + liveMode + ")"; color = Color.DimGray; break;
            }
            try
            {
                if (IsHandleCreated && !IsDisposed)
                    BeginInvoke((Action)(() => { if (btnStop.Enabled) SetStatus(text, color); }));
            }
            catch { }
        }

        void StopSender()
        {
            try { if (sender != null && !sender.HasExited) { sender.Kill(); sender.WaitForExit(4000); } } catch { }
            sender = null;
            liveState = ""; liveFps = "";
        }

        void OnStop(object sender2, EventArgs e)
        {
            SetStatus("Stopping...", Color.DimGray);
            btnStop.Enabled = false;
            StopSender();
            DisableVdd();
            SetStatus("Stopped — virtual display hidden.", Color.DimGray);
            btnStart.Enabled = true;
        }

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
