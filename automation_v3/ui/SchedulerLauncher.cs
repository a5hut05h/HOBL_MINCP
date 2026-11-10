using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class SchedulerLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(directory, "register_schedule_wpf.ps1");
            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(script))
                throw new FileNotFoundException("Keep this EXE beside register_schedule_wpf.ps1 in the automation_v3 UI folder.", script);
            if (!File.Exists(powershell))
                throw new FileNotFoundException("Windows PowerShell was not found.", powershell);

            string options = "";
            foreach (string arg in args)
            {
                switch (arg.ToLowerInvariant())
                {
                    case "--validate-only": options += " -ValidateOnly"; break;
                    case "--startup-check": options += " -StartupCheck"; break;
                    case "--preview": options += " -Preview"; break;
                    default: throw new ArgumentException("Unsupported option: " + arg);
                }
            }

            var start = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File \"" + script + "\"" + options,
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            var output = new StringBuilder();
            var errors = new StringBuilder();
            using (var process = new Process { StartInfo = start })
            {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null) output.AppendLine(e.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null) errors.AppendLine(e.Data);
                };
                if (!process.Start()) throw new InvalidOperationException("Could not start Windows PowerShell.");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("Scheduler exited with code " + process.ExitCode + ".\r\n" + errors + output);
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(" ERROR - " + ex.Message, "HOBL Automation V3 Scheduler", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
