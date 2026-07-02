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
        CheckBox chkUdp, chkTouch, chkHevc, chkHdr, chkEncrypt, chkAudio, chkMute;
        ComboBox cmbFps, cmbEnc;
        TextBox txtBit, txtIp;
        NumericUpDown numDelay;
        Button btnStart, btnStop;
        Label lblStatus, lblCode;
        ToolTip tip;
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
            ClientSize = new Size(400, 544);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9.5f);
            BackColor = Color.White;

            tip = new ToolTip { AutoPopDelay = 30000, InitialDelay = 350, ReshowDelay = 100, ShowAlways = true };

            // ── Connection ────────────────────────────────────────────────
            var grpConn = new GroupBox { Text = "Connection", Location = new Point(12, 10), Size = new Size(376, 96) };
            rbUsb = new RadioButton { Text = "USB  (auto-detect)", Location = new Point(12, 24), AutoSize = true, Checked = true };
            rbWifi = new RadioButton { Text = "Wi-Fi", Location = new Point(12, 50), AutoSize = true };
            var lblIp = new Label { Text = "IP (optional):", Location = new Point(92, 52), AutoSize = true };
            txtIp = new TextBox { Location = new Point(180, 49), Width = 118, Enabled = false, Text = "" };
            tip.SetToolTip(txtIp, Wrap("Optional. Enter the tablet's IP if auto-discovery fails (guest / AP-isolated networks). Leave blank to auto-find it on the LAN."));
            chkUdp = new CheckBox { Text = "Low-latency UDP", Location = new Point(30, 72), AutoSize = true, Enabled = false };
            var iUdp = Info(72, "Send video over UDP for lower latency on Wi-Fi. Helps on lossy / high-latency links; on a good 5 GHz link, plain TCP is usually smoother.", chkUdp);
            rbWifi.CheckedChanged += (s, e) => { chkUdp.Enabled = rbWifi.Checked; txtIp.Enabled = rbWifi.Checked; };
            grpConn.Controls.AddRange(new Control[] { rbUsb, rbWifi, lblIp, txtIp, chkUdp, iUdp });

            // ── Video ─────────────────────────────────────────────────────
            var grpVid = new GroupBox { Text = "Video", Location = new Point(12, 114), Size = new Size(376, 100) };
            var lblFps = new Label { Text = "FPS:", Location = new Point(12, 28), AutoSize = true };
            cmbFps = new ComboBox { Location = new Point(70, 25), Width = 70, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbFps.Items.AddRange(new object[] { "60", "120" }); cmbFps.SelectedIndex = 0;
            var iFps = Info(28, "120 fps drops the virtual display to 2560x1600 (the tablet upscales) so the pipeline can sustain 120 Hz. 60 fps runs at native 2960x1848.", cmbFps);
            var lblEnc = new Label { Text = "Encoder:", Location = new Point(158, 28), AutoSize = true };
            cmbEnc = new ComboBox { Location = new Point(224, 25), Width = 96, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbEnc.Items.AddRange(new object[] { "Auto", "nvenc", "qsv", "mf", "amf", "x264" }); cmbEnc.SelectedIndex = 0;
            tip.SetToolTip(cmbEnc, Wrap("Leave on Auto - it picks the best working GPU encoder (NVENC, QSV, MF, AMF, x264 in order). Pin one only for troubleshooting."));
            var lblBit = new Label { Text = "Bitrate (Kbps):", Location = new Point(12, 64), AutoSize = true };
            txtBit = new TextBox { Text = "25000", Location = new Point(115, 61), Width = 90 };
            tip.SetToolTip(txtBit, Wrap("Video bitrate in Kbps. Higher = crisper text, more bandwidth. 25000 is a good default; try 40000 for very sharp text."));
            grpVid.Controls.AddRange(new Control[] { lblFps, cmbFps, iFps, lblEnc, cmbEnc, lblBit, txtBit });

            // ── Options ───────────────────────────────────────────────────
            // Short labels; the full description is on the ⓘ (and on hover of the row).
            var grpOpt = new GroupBox { Text = "Options", Location = new Point(12, 222), Size = new Size(376, 214) };
            chkTouch = new CheckBox { Text = "Touch input", Location = new Point(12, 24), AutoSize = true, Checked = true };
            var iTouch = Info(24, "Tablet touches control the PC - tap = click, drag = move / scroll, long-press = right-click. S Pen pressure & hover work too.", chkTouch);
            chkHevc = new CheckBox { Text = "HEVC / H.265", Location = new Point(12, 50), AutoSize = true };
            var iHevc = Info(50, "H.265 encoding - sharper at high resolution / FPS for the same bitrate. Needs tablet HEVC support (the S9 Ultra has it).", chkHevc);
            chkHdr = new CheckBox { Text = "HDR", Location = new Point(12, 76), AutoSize = true };
            var iHdr = Info(76, "Experimental - for HDR video content only. The normal SDR desktop looks washed out, so leave this OFF for general use.", chkHdr);
            chkAudio = new CheckBox { Text = "Desktop audio", Location = new Point(12, 102), AutoSize = true };
            var iAudio = Info(102, "Play the PC's sound on the tablet over the same link (no extra driver needed).", chkAudio);
            chkMute = new CheckBox { Text = "› Mute PC speakers", Location = new Point(30, 128), AutoSize = true, Enabled = false };
            var iMute = Info(128, "Sound plays only on the tablet; the PC's own speakers stay silent while streaming (restored when you Stop).", chkMute);
            var lblDelay = new Label { Text = "› A/V sync delay (ms):", Location = new Point(30, 157), AutoSize = true, Enabled = false };
            numDelay = new NumericUpDown { Location = new Point(180, 154), Width = 62, Minimum = 20, Maximum = 500, Value = 40, Increment = 5, Enabled = false };
            var iDelay = Info(157, "Audio delay for lip-sync (ms). Higher = audio plays later; lower it if audio lags the video. ~40 matches the tablet's own video; ~20 for watching the laptop with the tablet as a speaker.", numDelay);
            chkAudio.CheckedChanged += (s, e) => {
                chkMute.Enabled = chkAudio.Checked; numDelay.Enabled = chkAudio.Checked;
                lblDelay.Enabled = chkAudio.Checked; iMute.Enabled = iDelay.Enabled = chkAudio.Checked;
                if (!chkAudio.Checked) chkMute.Checked = false;
            };
            chkEncrypt = new CheckBox { Text = "Encrypt", Location = new Point(12, 184), AutoSize = true };
            var iEnc = Info(184, "Require a pairing code (shown below) on the tablet. Encrypts video, touch and audio with AES-256 - use it on untrusted Wi-Fi.", chkEncrypt);
            chkEncrypt.CheckedChanged += OnEncryptToggled;
            grpOpt.Controls.AddRange(new Control[] {
                chkTouch, iTouch, chkHevc, iHevc, chkHdr, iHdr, chkAudio, iAudio,
                chkMute, iMute, lblDelay, numDelay, iDelay, chkEncrypt, iEnc });

            // ── Pairing code + status + buttons ───────────────────────────
            lblCode = new Label { Text = "", Location = new Point(14, 442), Size = new Size(374, 22), ForeColor = Color.MediumBlue, Font = new Font("Consolas", 11f, FontStyle.Bold) };
            lblStatus = new Label { Text = "Ready.", Location = new Point(14, 466), Size = new Size(374, 20), ForeColor = Color.DimGray };
            btnStart = new Button { Text = "Start Streaming", Location = new Point(12, 494), Size = new Size(182, 38), BackColor = Color.FromArgb(0, 120, 212), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
            btnStart.FlatAppearance.BorderSize = 0;
            btnStop = new Button { Text = "Stop", Location = new Point(206, 494), Size = new Size(182, 38), Enabled = false };
            btnStart.Click += OnStart;
            btnStop.Click += OnStop;

            Controls.AddRange(new Control[] { grpConn, grpVid, grpOpt, lblCode, lblStatus, btnStart, btnStop });

            FormClosing += (s, e) => { StopSender(); DisableVdd(); };

            if (!File.Exists(exePath))
                SetStatus("WARNING: sender not found at " + exePath, Color.Firebrick);
        }

        // WinForms tooltips don't word-wrap on their own — long descriptions render
        // as one endless line. Break at word boundaries every ~52 chars instead.
        static string Wrap(string text)
        {
            const int width = 52;
            var sb = new System.Text.StringBuilder();
            int lineLen = 0;
            foreach (string word in text.Split(' '))
            {
                if (lineLen > 0 && lineLen + 1 + word.Length > width)
                {
                    sb.Append("\r\n");
                    lineLen = 0;
                }
                else if (lineLen > 0)
                {
                    sb.Append(' ');
                    lineLen++;
                }
                sb.Append(word);
                lineLen += word.Length;
            }
            return sb.ToString();
        }

        // A small blue ⓘ marker at the right edge of a row. The full description is a
        // tooltip on the marker and on any related controls (so hovering the row works).
        Label Info(int y, string text, params Control[] related)
        {
            var l = new Label
            {
                Text = "ⓘ",   // circled 'i' info glyph
                Location = new Point(350, y),
                AutoSize = true,
                ForeColor = Color.FromArgb(0, 120, 212),
                Cursor = Cursors.Hand,
                Font = new Font("Segoe UI", 10.5f)
            };
            string wrapped = Wrap(text);
            tip.SetToolTip(l, wrapped);
            foreach (var c in related) tip.SetToolTip(c, wrapped);
            return l;
        }

        string ResolveSenderPath()
        {
            // Packaged: the sender sits beside this launcher. Dev tree: the launcher
            // may run from windows-sender\launcher\ (sender in ..\build\Release) or
            // from windows-sender\build\Release\ (sender beside it). Try each.
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
                lblCode.Text = "Pairing code:   " + pairCode;
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
            // Encryption now works on both transports (the sender encrypts NALs for
            // UDP and length-prefixed TCP), so honour the user's UDP choice directly —
            // no need to force UDP when encrypting. TCP stays smoother on good Wi-Fi.
            if (chkUdp.Checked && chkUdp.Enabled) sb.Append(" --udp");
            if (chkHdr.Checked) sb.Append(" --hdr");
            else if (chkHevc.Checked) sb.Append(" --hevc");
            if (!chkTouch.Checked) sb.Append(" --no-touch");
            if (chkAudio.Checked) sb.Append(" --audio");
            if (chkAudio.Checked) sb.Append(" --audio-delay-ms " + (int)numDelay.Value);
            if (chkMute.Checked && chkMute.Enabled) sb.Append(" --mute-local");
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
            SetStatus("Stopped - virtual display hidden.", Color.DimGray);
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
