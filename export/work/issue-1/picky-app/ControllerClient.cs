using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PickyVPN.App;

internal sealed record ControllerStatus(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("profile")] string Profile,
    [property: JsonPropertyName("delivery")] string Delivery,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("observed_utc")] string ObservedUtc,
    [property: JsonPropertyName("context")] string Context = "")
{
    internal static ControllerStatus Local(string state, string code, string context = "") =>
        new("pickyvpn-controller-status-v1", "primary", ControllerClient.Delivery, state, code, DateTime.UtcNow.ToString("O"), context);
}

internal sealed class ControllerClient
{
    private const string PipeName = "PickyVPN.Controller.D4";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    internal static string Delivery =>
        string.Equals(Environment.GetEnvironmentVariable("PICKYVPN_DELIVERY"), "lan", StringComparison.OrdinalIgnoreCase) ? "lan" : "external";

    private static string Endpoint
    {
        get
        {
            var developmentOverride = Environment.GetEnvironmentVariable("PICKYVPN_ENDPOINT");
            if (!string.IsNullOrWhiteSpace(developmentOverride)) return developmentOverride;
            return Delivery == "lan" ? "192.168.1.160" : "91.235.176.50";
        }
    }

    private string ProgramRoot => AppContext.BaseDirectory;
    private string ControllerRoot => Path.Combine(ProgramRoot, "controller");
    private string EngineRoot => Path.Combine(ProgramRoot, "engine", "sing-box");
    private string PublicMetadataPath => Path.Combine(EngineRoot, "public-vless-metadata.json");
    private string RuntimeRoot => ProductPaths.RuntimeRoot;

    private string CredentialPath => ProductPaths.CredentialPath;

    private sealed record PipeAttempt(ControllerStatus? Status, bool Ambiguous);

    internal bool NeedsHostRecovery
    {
        get
        {
            return File.Exists(Path.Combine(RuntimeRoot, "state", "controller.json"));
        }
    }

    internal async Task<ControllerStatus> InvokeAsync(string action, bool apply, AppSettings settings, CancellationToken cancellationToken = default)
    {
        var request = CreateRequest(action, settings);

        if (!apply)
        {
            var hosted = await TryPipeAsync(request, TimeSpan.FromMilliseconds(180), cancellationToken);
            if (hosted.Status is not null) return hosted.Status;
            return await InvokeReadOnlyPowerShellAsync(action, cancellationToken);
        }

        var immediate = await TryPipeAsync(request, TimeSpan.FromMilliseconds(180), cancellationToken);
        if (immediate.Status is not null) return immediate.Status;
        if (action == "disconnect" && immediate.Ambiguous)
        {
            return await InvokeReadOnlyPowerShellAsync("status", cancellationToken);
        }
        StartElevatedHost();
        for (var attempt = 0; attempt < 80; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var response = await TryPipeAsync(request, TimeSpan.FromMilliseconds(250), cancellationToken);
            if (response.Status is not null) return response.Status;
            if (action == "disconnect" && response.Ambiguous)
            {
                return await InvokeReadOnlyPowerShellAsync("status", cancellationToken);
            }
            await Task.Delay(100, cancellationToken);
        }
        throw new InvalidOperationException("CONTROLLER_HOST_START_TIMEOUT");
    }

    // Exit never starts a new elevated host. A resident host must prove clean idle and
    // stop itself; without one, read-only status proves that no owned state remains.
    internal async Task<ControllerStatus> ShutdownAsync(AppSettings settings, CancellationToken cancellationToken = default)
    {
        if (IsControllerHostRunning())
        {
            var hosted = await TryPipeAsync(CreateRequest("shutdown", settings), TimeSpan.FromSeconds(2), cancellationToken);
            return hosted.Status ?? ControllerStatus.Local("Error", "CONTROLLER_SHUTDOWN_UNAVAILABLE");
        }
        if (NeedsHostRecovery) return ControllerStatus.Local("Error", "CONTROLLER_SHUTDOWN_RECONCILIATION_REQUIRED");
        var observed = await InvokeReadOnlyPowerShellAsync("status", cancellationToken);
        if (observed.State is "Ready" or "Disconnected" or "Unconfigured")
            return ControllerStatus.Local("Ready", "SHUTDOWN_READY");
        return observed.State == "Error" ? observed : ControllerStatus.Local("Error", "CONTROLLER_SHUTDOWN_CLEAN_IDLE_REQUIRED");
    }

    private static bool IsControllerHostRunning()
    {
        try
        {
            using var mutex = Mutex.OpenExisting(@"Local\PickyVPN.Controller.D4");
            return true;
        }
        catch (WaitHandleCannotBeOpenedException) { return false; }
        catch (UnauthorizedAccessException) { return true; }
    }

    private static string CreateRequest(string action, AppSettings settings) => JsonSerializer.Serialize(new
    {
        action,
        profile = "primary",
        delivery = Delivery,
        endpoint = Endpoint,
        kill_switch_enabled = settings.KillSwitchEnabled,
        kill_switch_mode = settings.KillSwitchMode.ToString(),
    });

    private async Task<PipeAttempt> TryPipeAsync(string request, TimeSpan timeout, CancellationToken cancellationToken)
    {
        try
        {
            await using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            await pipe.ConnectAsync(timeoutSource.Token);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
            await writer.WriteLineAsync(request.AsMemory(), cancellationToken);
            var line = await reader.ReadLineAsync(cancellationToken);
            return new PipeAttempt(ParseStatus(line), false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new PipeAttempt(null, false);
        }
        catch (IOException)
        {
            return new PipeAttempt(null, false);
        }
        catch (InvalidOperationException)
        {
            // The elevated host may close its one-shot pipe immediately after a successful
            // Disconnect. Treat an incomplete response as an unavailable host and use the
            // existing read-only status fallback instead of surfacing a transient UI Error.
            return new PipeAttempt(null, true);
        }
        catch (JsonException)
        {
            return new PipeAttempt(null, true);
        }
    }

    private void StartElevatedHost()
    {
        var executable = Path.Combine(ControllerRoot, "PickyVPN.Controller.exe");
        if (!File.Exists(executable)) throw new FileNotFoundException("CONTROLLER_HOST_NOT_BUILT");
        var start = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        start.ArgumentList.Add("--server");
        start.ArgumentList.Add($"--program-root={ProgramRoot}");
        try
        {
            using var process = Process.Start(start) ?? throw new InvalidOperationException("CONTROLLER_PROCESS_START_FAILED");
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            throw new InvalidOperationException("ELEVATION_CANCELLED", error);
        }
    }

    private async Task<ControllerStatus> InvokeReadOnlyPowerShellAsync(string action, CancellationToken cancellationToken)
    {
        var controllerPath = Path.Combine(ControllerRoot, "Invoke-PickyVPNController.ps1");
        var requestPath = Path.Combine(Path.GetTempPath(), $"pickyvpn-controller-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(requestPath, JsonSerializer.Serialize(new { action, profile = "primary", delivery = Delivery, endpoint = Endpoint }), cancellationToken);
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                WorkingDirectory = ControllerRoot,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-ExecutionPolicy");
            start.ArgumentList.Add("Bypass");
            start.ArgumentList.Add("-File");
            start.ArgumentList.Add(controllerPath);
            start.ArgumentList.Add("-RequestPath");
            start.ArgumentList.Add(requestPath);
            start.ArgumentList.Add("-RuntimeRoot");
            start.ArgumentList.Add(RuntimeRoot);
            start.ArgumentList.Add("-CredentialPath");
            start.ArgumentList.Add(CredentialPath);
            start.ArgumentList.Add("-PublicMetadataPath");
            start.ArgumentList.Add(PublicMetadataPath);
            start.ArgumentList.Add("-EngineRoot");
            start.ArgumentList.Add(EngineRoot);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("CONTROLLER_PROCESS_START_FAILED");
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var output = (await outputTask).Trim();
            _ = await errorTask;
            if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("CONTROLLER_PROCESS_FAILED");
            return ParseStatus(output);
        }
        finally
        {
            try { File.Delete(requestPath); } catch { }
        }
    }

    private static ControllerStatus ParseStatus(string? json)
    {
        var status = JsonSerializer.Deserialize<ControllerStatus>(json ?? string.Empty, JsonOptions);
        if (status is null || status.Schema != "pickyvpn-controller-status-v1") throw new InvalidOperationException("CONTROLLER_RESPONSE_INVALID");
        return status;
    }

}
