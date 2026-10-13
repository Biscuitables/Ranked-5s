using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Ranked 5s Ban Advisor")]
[assembly: AssemblyDescription("Champ select scouting dashboard for League of Legends")]
[assembly: AssemblyProduct("Ranked 5s Ban Advisor")]
[assembly: AssemblyCompany("Ranked 5s Ban Advisor")]
[assembly: AssemblyCopyright("Personal use")]
[assembly: AssemblyVersion("1.6.3.0")]
[assembly: AssemblyFileVersion("1.6.3.0")]

class Launcher {
    const string Url = "http://localhost:8765/";
    static Process ps;
    static NotifyIcon tray;
    static bool quitting;
    static string dir, logPath;
    static StreamWriter log;

    [STAThread]
    static void Main(string[] args) {
        bool created;
        using (var mtx = new Mutex(true, "BanAdvisor_SingleInstance", out created)) {
            if (!created) { OpenDashboard(); return; }   // already running: just show it
            Application.EnableVisualStyles();
            try {
                dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BanAdvisor");
                Directory.CreateDirectory(dir);
                Extract("BanAdvisor.ps1", Path.Combine(dir, "BanAdvisor.ps1"));
                Extract("index.html", Path.Combine(dir, "index.html"));
                logPath = Path.Combine(dir, "BanAdvisor.log");
                log = new StreamWriter(logPath, false, Encoding.UTF8) { AutoFlush = true };

                var sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(dir, "BanAdvisor.ps1") + "\"");
                foreach (var a in args) sb.Append(" \"").Append(a.Replace("\"", "")).Append("\"");
                var psi = new ProcessStartInfo("powershell.exe", sb.ToString()) {
                    UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = dir,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
                };
                ps = new Process { StartInfo = psi, EnableRaisingEvents = true };
                ps.OutputDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine(e.Data); };
                ps.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (log) log.WriteLine("ERROR: " + e.Data); };
                ps.Exited += OnExited;
                ps.Start();
                ps.BeginOutputReadLine();
                ps.BeginErrorReadLine();
            } catch (Exception ex) {
                MessageBox.Show("Ranked 5s Ban Advisor could not start:\n\n" + ex.Message, "Ranked 5s Ban Advisor", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            var menu = new ContextMenuStrip();
            var open = new ToolStripMenuItem("Open dashboard", null, (s, e) => OpenDashboard());
            open.Font = new Font(open.Font, FontStyle.Bold);
            menu.Items.Add(open);
            menu.Items.Add(new ToolStripMenuItem("Show log", null, (s, e) => { try { Process.Start("notepad.exe", "\"" + logPath + "\""); } catch { } }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit Ranked 5s Ban Advisor", null, (s, e) => Quit()));

            tray = new NotifyIcon {
                Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath),
                Text = "Ranked 5s Ban Advisor",
                ContextMenuStrip = menu,
                Visible = true
            };
            tray.DoubleClick += (s, e) => OpenDashboard();
            tray.BalloonTipClicked += (s, e) => OpenDashboard();
            tray.ShowBalloonTip(5000, "Ranked 5s Ban Advisor is running",
                "The dashboard opens in your browser. Use this icon near the clock to reopen it or quit.", ToolTipIcon.Info);

            Application.Run();
            tray.Visible = false;
            tray.Dispose();
        }
    }

    static void OnExited(object sender, EventArgs e) {
        if (quitting) return;
        quitting = true;
        string tail = "";
        try { lock (log) { log.Flush(); } tail = File.ReadAllText(logPath); if (tail.Length > 800) tail = tail.Substring(tail.Length - 800); } catch { }
        MessageBox.Show("Ranked 5s Ban Advisor stopped unexpectedly.\n\nLast messages:\n" + tail, "Ranked 5s Ban Advisor", MessageBoxButtons.OK, MessageBoxIcon.Information);
        Application.Exit();
    }

    static void Quit() {
        quitting = true;
        try { if (ps != null && !ps.HasExited) ps.Kill(); } catch { }
        Application.Exit();
    }

    static void OpenDashboard() {
        try { Process.Start(new ProcessStartInfo(Url) { UseShellExecute = true }); } catch { }
    }

    static void Extract(string name, string path) {
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (var f = File.Create(path)) { s.CopyTo(f); }
    }
}
