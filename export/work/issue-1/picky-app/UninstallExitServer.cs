using System.IO.Pipes;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace PickyVPN.App;

// A package helper can request only the existing graceful D.7 exit boundary.
// The server is restricted to this user's SID; it never exposes controller actions.
internal sealed class UninstallExitServer : IDisposable
{
    internal const string PipeName = "PickyVPN.App.Uninstall.E2";
    private readonly CancellationTokenSource cancellation = new();

    internal Task RunAsync(Func<Task> requestExit) => Task.Run(async () =>
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await using var pipe = CreateCurrentUserPipe();
                await pipe.WaitForConnectionAsync(cancellation.Token);
                using var reader = new StreamReader(pipe, Encoding.UTF8, false, 256, leaveOpen: true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 256, leaveOpen: true) { AutoFlush = true };
                if (!string.Equals(await reader.ReadLineAsync(cancellation.Token), "graceful-exit", StringComparison.Ordinal))
                {
                    await writer.WriteLineAsync("rejected");
                    continue;
                }
                await writer.WriteLineAsync("accepted");
                await requestExit();
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch (IOException) { }
        }
    });

    private static NamedPipeServerStream CreateCurrentUserPipe()
    {
        var user = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("APP_USER_SID_UNAVAILABLE");
        var security = new PipeSecurity();
        security.SetSecurityDescriptorSddlForm(
            $"O:{user.Value}D:P(A;;GRGW;;;{user.Value})",
            AccessControlSections.Owner | AccessControlSections.Access);
        return NamedPipeServerStreamAcl.Create(
            PipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            256,
            256,
            security,
            HandleInheritability.None,
            (PipeAccessRights)0);
    }

    internal static bool TryRequestGracefulExit()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
            pipe.Connect(5000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 256, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 256, leaveOpen: true);
            writer.WriteLine("graceful-exit");
            return string.Equals(reader.ReadLine(), "accepted", StringComparison.Ordinal);
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (TimeoutException) { return false; }
    }

    public void Dispose()
    {
        cancellation.Cancel();
        cancellation.Dispose();
    }
}
