using System.Windows;
using System.Runtime.InteropServices;

namespace PickyVPN.App;

public partial class App : Application
{
    private const string InstanceMutexName = @"Local\PickyVPN.App.PortfolioCapture";
    private const string OpenEventName = @"Local\PickyVPN.App.Open.PortfolioCapture";
    private Mutex? instanceMutex;
    private EventWaitHandle? openSignal;
    private RegisteredWaitHandle? openSignalRegistration;
    private UninstallExitServer? uninstallExitServer;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    protected override void OnStartup(StartupEventArgs e)
    {
        const string taskbarAppId = "PickyVPN.App";
        _ = SetCurrentProcessExplicitAppUserModelID(taskbarAppId);
        instanceMutex = new Mutex(true, InstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            if (e.Args.Contains("--uninstall-exit", StringComparer.OrdinalIgnoreCase)) _ = UninstallExitServer.TryRequestGracefulExit();
            else TrySignalExistingInstance();
            Shutdown();
            return;
        }
        base.OnStartup(e);
        var window = new MainWindow(e.Args);
        openSignal = new EventWaitHandle(false, EventResetMode.AutoReset, OpenEventName);
        openSignalRegistration = ThreadPool.RegisterWaitForSingleObject(openSignal, (_, _) => _ = Dispatcher.InvokeAsync(window.RestoreFromTray), null, -1, false);
        uninstallExitServer = new UninstallExitServer();
        _ = uninstallExitServer.RunAsync(() => Dispatcher.InvokeAsync(window.RequestUninstallExitAsync).Task.Unwrap());
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        openSignalRegistration?.Unregister(null);
        openSignal?.Dispose();
        uninstallExitServer?.Dispose();
        instanceMutex?.Dispose();
        base.OnExit(e);
    }

    private static void TrySignalExistingInstance()
    {
        try
        {
            using var signal = EventWaitHandle.OpenExisting(OpenEventName);
            signal.Set();
        }
        catch (WaitHandleCannotBeOpenedException) { }
        catch (UnauthorizedAccessException) { }
    }
}
