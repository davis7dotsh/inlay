using System;
using System.ComponentModel;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows;
using Forms = System.Windows.Forms;

namespace Inlay.Windows;

internal sealed class App : Application
{
    [STAThread]
    public static int Main(string[] args)
    {
        // For managed installs: the setup secret must come from a redirected pipe,
        // never argv, environment, a log, or a scheduled task. Don't rotate an existing identity.
        if (args.Length != 0 && args[0] == "--enroll-stdin")
        {
            if (args.Length != 2 || !Console.IsInputRedirected) return 2;
            try
            {
                var settings = ClientSettings.Load();
                if (settings.OpenApi() != null) return 3;
                string? token = Console.ReadLine();
                if (string.IsNullOrWhiteSpace(token)) return 2;
                settings.ConnectAsync(args[1], token, settings.DeviceName).GetAwaiter().GetResult();
                return 0;
            }
            catch { return 1; } // Never echo a token or untrusted server response.
        }
        using var mutex = new Mutex(true, @"Local\Inlay.Dictation.Client", out var first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Inlay.Dictation.Show");
        if (!first)
        {
            show.Set();
            return 0;
        }
        try
        {
            var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            return app.RunClient(show, args.Contains("--tray", StringComparer.Ordinal));
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Inlay couldn’t start", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }

    private int RunClient(EventWaitHandle show, bool trayOnly)
    {
        using var controller = new AppController();
        var window = new MainWindow(controller);
        MainWindow = window;
        using var icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? (Icon)SystemIcons.Application.Clone();
        using var menu = new Forms.ContextMenuStrip();
        using var tray = new Forms.NotifyIcon { Icon = icon, Text = "Inlay", ContextMenuStrip = menu, Visible = true };
        void Open()
        {
            window.Show();
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            window.Activate();
        }
        controller.Notice += message =>
        {
            if (!window.IsActive) tray.ShowBalloonTip(3500, "Inlay", message, Forms.ToolTipIcon.Info);
        };
        tray.BalloonTipClicked += (_, _) => Open();
        var exiting = false;
        void Closing(object? sender, CancelEventArgs e)
        {
            if (exiting) return;
            e.Cancel = true;
            window.Hide();
        }
        void Quit()
        {
            exiting = true;
            tray.Visible = false;
            Shutdown();
        }
        window.Closing += Closing;
        menu.Items.Add("Open Inlay", null, (_, _) => Open());
        menu.Items.Add("Quit Inlay", null, (_, _) => Quit());
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) Open(); };
        var signal = ThreadPool.RegisterWaitForSingleObject(show, (_, _) => Dispatcher.BeginInvoke((Action)Open), null, -1, false);
        try
        {
            if (!trayOnly) Open();
            Dispatcher.BeginInvoke((Action)(() => _ = controller.RefreshAsync()));
            return Run();
        }
        finally
        {
            signal.Unregister(null);
            window.Closing -= Closing;
        }
    }
}
