using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace PickyVPN.App;

public partial class MainWindow : Window
{
    private static string ProductVersion => typeof(MainWindow).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()!
        .InformationalVersion.Split('+', 2)[0];

    private enum Screen { Home, Settings, Server, Transport, Routing, Interface, Network, Credential, KillSwitch, KillSwitchMode, Diagnostics, About }
    private enum ThemeChoice { System, Light, Dark }

    private sealed record Palette(string Canvas, string Surface, string Chrome, string Ivory, string Muted, string Accent)
    {
        internal static readonly Palette Light = new("#EEE7DB", "#FFF9EE", "#252629", "#F4F0E6", "#6E6961", "#C4A46A");
        internal static readonly Palette Dark = new("#101B2D", "#18263D", "#0B1423", "#F4F0E6", "#A6B1C2", "#B08D57");
    }

    private readonly ControllerClient controller = new();
    private AppSettings appSettings = AppSettings.Load();
    private readonly DispatcherTimer statusTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly string[] startupArguments;
    private ControllerStatus status = ControllerStatus.Local("Unconfigured", "STATUS_NOT_OBSERVED");
    private DispatcherTimer? ringTimer;
    private Screen currentScreen = Screen.Home;
    private ThemeChoice themeChoice = ThemeChoice.System;
    private Palette palette = Palette.Dark;
    private bool isLight;
    private bool operationPending;
    private bool refreshPending;
    private bool errorAcknowledged;
    private bool allowApplicationExit;
    private bool exitPending;
    private ControllerStatus? lastError;
    private Task? activeOperation;
    private Forms.NotifyIcon? trayIcon;
    private Forms.ToolStripMenuItem? trayConnectItem;
    private Forms.ToolStripMenuItem? trayDisconnectItem;
    private Forms.ToolStripMenuItem? trayExitItem;
    private Drawing.Icon? trayImage;
    private long operationGeneration;
    private IntPtr taskbarLargeIcon;
    private IntPtr transparentCaptionIcon;

    public MainWindow(string[] arguments)
    {
        startupArguments = arguments;
        InitializeComponent();
        SetTheme(ThemeChoice.System);
        BrandMarkBody.Source = new BitmapImage(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "assets", "picky-stoat-body-dark-1024.png")));
        Title = string.Empty;
        HomeNavButton.Click += (_, _) => ShowHome();
        SettingsNavButton.Click += (_, _) => ShowSettings();
        SourceInitialized += (_, _) => InitializeNativeWindow();
        statusTimer.Tick += async (_, _) => await RefreshStatusAsync();
        Loaded += OnLoaded;
        Closing += OnWindowClosing;
        Closed += OnWindowClosed;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (controller.NeedsHostRecovery)
        {
            try { status = await controller.InvokeAsync("status", true, appSettings); }
            catch (InvalidOperationException error) when (error.Message == "ELEVATION_CANCELLED") { status = ControllerStatus.Local("Error", "ELEVATION_CANCELLED"); }
            catch { status = ControllerStatus.Local("Error", "CONTROLLER_RECOVERY_FAILED"); }
            PublishErrorEvent(status, true);
        }
        else
        {
            await RefreshStatusAsync();
        }
        var requestedTheme = ArgumentValue("--theme=");
        if (Enum.TryParse<ThemeChoice>(requestedTheme, true, out var parsedTheme)) SetTheme(parsedTheme);
        ShowHome();
        var requestedScreen = ArgumentValue("--screen=");
        if (Enum.TryParse<Screen>(requestedScreen, true, out var parsedScreen)) ShowRequestedScreen(parsedScreen);
        var screenshotPath = ArgumentValue("--screenshot=");
        if (!string.IsNullOrWhiteSpace(screenshotPath))
        {
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
            SaveScreenshot(screenshotPath);
            allowApplicationExit = true;
            Close();
            return;
        }
        statusTimer.Start();
        UpdateTrayCommands();
    }

    private string? ArgumentValue(string prefix) => startupArguments.FirstOrDefault(argument => argument.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))?[prefix.Length..];

    private void ShowRequestedScreen(Screen screen)
    {
        switch (screen)
        {
            case Screen.Settings: ShowSettings(); break;
            case Screen.Server: ShowSelection(Screen.Server, "Server", "Aktau"); break;
            case Screen.Transport: ShowSelection(Screen.Transport, "Protocol", "VLESS"); break;
            case Screen.Routing: ShowSelection(Screen.Routing, "Tunneling", "Full"); break;
            case Screen.Interface: ShowInterface(); break;
            case Screen.Network: ShowNetwork(); break;
            case Screen.Credential: ShowCredential(); break;
            case Screen.KillSwitch: ShowKillSwitch(); break;
            case Screen.KillSwitchMode: ShowKillSwitchMode(); break;
            case Screen.Diagnostics: ShowDiagnostics(); break;
            case Screen.About: ShowAbout(); break;
            default: ShowHome(); break;
        }
    }

    private void SaveScreenshot(string path)
    {
        var outputPath = System.IO.Path.GetFullPath(path);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(outputPath)!);
        var width = Math.Max(1, (int)ActualWidth);
        var height = Math.Max(1, (int)ActualHeight);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(outputPath);
        encoder.Save(stream);
    }

    private async Task RefreshStatusAsync()
    {
        // Status is a cheap controller snapshot. DNS/HTTPS health runs independently in
        // the elevated lifecycle host and therefore cannot occupy this UI polling path.
        if (operationPending || refreshPending) return;
        var observedGeneration = operationGeneration;
        refreshPending = true;
        ControllerStatus observed;
        try
        {
            observed = await controller.InvokeAsync("status", false, appSettings);
        }
        catch
        {
            if (status.State is "Connected" or "Degraded") return;
            observed = ControllerStatus.Local("Error", "CONTROLLER_STATUS_FAILED");
        }
        finally
        {
            refreshPending = false;
        }
        if (operationPending || observedGeneration != operationGeneration) return;
        if (errorAcknowledged && observed.State == "Error") return;
        if (status.State == "Error" && observed.State != "Error" && !errorAcknowledged) return;
        PublishErrorEvent(observed, status.State != "Error");
        if (observed.State != "Error") errorAcknowledged = false;
        status = observed;
        UpdateTrayCommands();
        if (currentScreen == Screen.Home) ShowHome();
        if (currentScreen == Screen.Diagnostics) ShowDiagnostics();
    }

    private Task RequestOperationAsync(string action, bool allowDuringExit = false)
    {
        if ((exitPending && !allowDuringExit) || operationPending) return activeOperation ?? Task.CompletedTask;
        activeOperation = ExecuteOperationAsync(action);
        return activeOperation;
    }

    private async Task ExecuteOperationAsync(string action)
    {
        if (operationPending) return;
        operationGeneration++;
        errorAcknowledged = false;
        operationPending = true;
        status = ControllerStatus.Local(action == "connect" ? "Connecting" : "Disconnecting", action == "connect" ? "CONTROLLER_CONNECT_IN_PROGRESS" : "CONTROLLER_DISCONNECT_IN_PROGRESS");
        UpdateTrayCommands();
        ShowHome();
        try
        {
            status = await controller.InvokeAsync(action, true, appSettings);
        }
        catch (InvalidOperationException error) when (error.Message == "ELEVATION_CANCELLED")
        {
            status = ControllerStatus.Local("Error", "ELEVATION_CANCELLED");
        }
        catch
        {
            status = ControllerStatus.Local("Error", "CONTROLLER_OPERATION_FAILED");
        }
        finally
        {
            operationPending = false;
            UpdateTrayCommands();
        }
        PublishErrorEvent(status, status.State == "Error");
        if (status.State != "Error") ShowHome();
    }

    private void SetTheme(ThemeChoice choice)
    {
        themeChoice = choice;
        var resolved = choice;
        if (choice == ThemeChoice.System)
        {
            var value = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0);
            resolved = value is int number && number == 1 ? ThemeChoice.Light : ThemeChoice.Dark;
        }
        isLight = resolved == ThemeChoice.Light;
        palette = isLight ? Palette.Light : Palette.Dark;
        Resources["CanvasBrush"] = Brush(palette.Canvas);
        Resources["SurfaceBrush"] = Brush(palette.Surface);
        Resources["SidebarBrush"] = Brush(palette.Chrome);
        Resources["SidebarTextBrush"] = Brush(palette.Ivory);
        Resources["MutedBrush"] = Brush(palette.Muted);
        Resources["AccentBrush"] = Brush(palette.Accent);
        Resources["TextBrush"] = Brush(isLight ? palette.Chrome : palette.Ivory);
        Resources["OutlineBrush"] = OpacityBrush(isLight ? palette.Chrome : palette.Muted, isLight ? .14 : .20);
        Resources["BaseRingBrush"] = OpacityBrush(palette.Muted, isLight ? .55 : .50);
        Resources["HoverBrush"] = OpacityBrush(palette.Accent, .11);
        Background = Brush(palette.Canvas);
        SetNativeWindowChrome();
    }

    private static SolidColorBrush Brush(string color) => new((Color)ColorConverter.ConvertFromString(color));
    private static SolidColorBrush OpacityBrush(string color, double opacity) => new((Color)ColorConverter.ConvertFromString(color)) { Opacity = opacity };
    private string TextColor => isLight ? palette.Chrome : palette.Ivory;

    private void SetNativeWindowChrome()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var immersiveDark = isLight ? 0 : 1;
        _ = DwmSetWindowAttribute(handle, 20, ref immersiveDark, 4);
        _ = DwmSetWindowAttribute(handle, 19, ref immersiveDark, 4);
        const long wsExDlgModalFrame = 0x0001;
        var extended = GetWindowLongPtr(handle, -20).ToInt64();
        _ = SetWindowLongPtr(handle, -20, new IntPtr(extended | wsExDlgModalFrame));
        _ = SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, 0x0027);
    }

    private void InitializeNativeWindow()
    {
        SetNativeWindowChrome();
        var handle = new WindowInteropHelper(this).Handle;
        var source = HwndSource.FromHwnd(handle);
        source?.AddHook(NativeWindowMessage);
        SetTaskbarIcon();
        CreateTrayIcon();
    }

    private IntPtr NativeWindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int wmDpiChanged = 0x02E0;
        if (message == wmDpiChanged)
        {
            var dpi = (uint)(wParam.ToInt64() & 0xFFFF);
            SetTaskbarIcon(dpi);
        }
        return IntPtr.Zero;
    }

    private void CreateTrayIcon()
    {
        if (trayIcon is not null) return;
        var iconPath = System.IO.Path.Combine(AppContext.BaseDirectory, "assets", "picky-taskbar.ico");
        trayImage = new Drawing.Icon(iconPath);
        trayConnectItem = new Forms.ToolStripMenuItem("Connect", null, (_, _) => Dispatcher.BeginInvoke(async () => await RequestOperationAsync("connect")));
        trayDisconnectItem = new Forms.ToolStripMenuItem("Disconnect", null, (_, _) => Dispatcher.BeginInvoke(async () => await RequestOperationAsync("disconnect")));
        var openItem = new Forms.ToolStripMenuItem("Open PickyVPN", null, (_, _) => Dispatcher.BeginInvoke(RestoreFromTray));
        trayExitItem = new Forms.ToolStripMenuItem("Exit PickyVPN", null, (_, _) => Dispatcher.BeginInvoke(async () => await ExitApplicationAsync()));
        var menu = new Forms.ContextMenuStrip();
        menu.Items.AddRange(new Forms.ToolStripItem[] { trayConnectItem, trayDisconnectItem, openItem, trayExitItem });
        trayIcon = new Forms.NotifyIcon { Icon = trayImage, Text = "PickyVPN", ContextMenuStrip = menu, Visible = true };
        trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(RestoreFromTray);
        UpdateTrayCommands();
    }

    internal void RestoreFromTray()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    private void UpdateTrayCommands()
    {
        if (trayIcon is null || trayConnectItem is null || trayDisconnectItem is null || trayExitItem is null) return;
        var stable = !operationPending && !exitPending;
        trayConnectItem.Enabled = stable && (status.State is "Ready" or "Disconnected");
        trayDisconnectItem.Enabled = stable && (status.State is "Connected" or "Degraded");
        trayExitItem.Enabled = !exitPending;
    }

    private async Task ExitApplicationAsync()
    {
        if (exitPending) return;
        exitPending = true;
        UpdateTrayCommands();
        try
        {
            if (operationPending && activeOperation is not null) await activeOperation;
            await RequestOperationAsync("disconnect", allowDuringExit: true);
            if (status.State == "Error") return;
            if (status.State is "Connecting" or "Disconnecting")
            {
                status = ControllerStatus.Local("Error", "CONTROLLER_SHUTDOWN_CLEAN_IDLE_REQUIRED");
                PublishErrorEvent(status, true);
                return;
            }
            var shutdownStatus = await controller.ShutdownAsync(appSettings);
            if (shutdownStatus.State == "Error")
            {
                status = shutdownStatus;
                PublishErrorEvent(status, true);
                return;
            }
            allowApplicationExit = true;
            trayIcon?.Dispose();
            trayIcon = null;
            Close();
        }
        catch
        {
            status = ControllerStatus.Local("Error", "CONTROLLER_SHUTDOWN_FAILED");
            PublishErrorEvent(status, true);
        }
        finally
        {
            exitPending = false;
            UpdateTrayCommands();
        }
    }

    internal Task RequestUninstallExitAsync() => ExitApplicationAsync();

    private void OnWindowClosing(object? sender, System.ComponentModel.CancelEventArgs eventArgs)
    {
        if (allowApplicationExit) return;
        eventArgs.Cancel = true;
        Hide();
    }

    private void OnWindowClosed(object? sender, EventArgs eventArgs)
    {
        statusTimer.Stop();
        ringTimer?.Stop();
        trayIcon?.Dispose();
        trayImage?.Dispose();
        ReleaseTaskbarIcons();
    }

    private void ResetPage(Screen screen, bool homeRoot)
    {
        ringTimer?.Stop();
        ringTimer = null;
        ContentHost.Children.Clear();
        ContentHost.RowDefinitions.Clear();
        currentScreen = screen;
        SetRootSelection(homeRoot);
    }

    private void SetRootSelection(bool home)
    {
        HomeNavButton.Background = Brushes.Transparent;
        SettingsNavButton.Background = Brushes.Transparent;
        HomeNavIcon.Stroke = Brush(home ? palette.Accent : palette.Ivory);
        HomeNavLabel.Foreground = Brush(home ? palette.Accent : palette.Ivory);
        SettingsNavIcon.Stroke = Brush(home ? palette.Ivory : palette.Accent);
        SettingsNavLabel.Foreground = Brush(home ? palette.Ivory : palette.Accent);
    }

    private StackPanel NewPagePanel()
    {
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top };
        ContentHost.Children.Add(panel);
        return panel;
    }

    private TextBlock Text(string value, double size = 14, string? color = null, FontWeight? weight = null, Thickness? margin = null) => new()
    {
        Text = value,
        FontSize = size,
        Foreground = Brush(color ?? TextColor),
        FontWeight = weight ?? FontWeights.Normal,
        Margin = margin ?? new Thickness(0),
        TextWrapping = TextWrapping.NoWrap,
    };

    private static System.Windows.Shapes.Path VectorIcon(string data, string color, double width = 18, double height = 18) => new()
    {
        Data = Geometry.Parse(data),
        Stroke = Brush(color),
        StrokeThickness = 2,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
        Fill = Brushes.Transparent,
        Stretch = Stretch.Uniform,
        Width = width,
        Height = height,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private Button RowButton(string label, string value, Action action)
    {
        var button = new Button { Style = (Style)FindResource("RowButtonStyle") };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        var labelText = Text(label, 15, weight: FontWeights.SemiBold);
        labelText.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(labelText);
        if (!string.IsNullOrWhiteSpace(value))
        {
            var valueText = Text(value, 14, palette.Muted, margin: new Thickness(8, 0, 8, 0));
            valueText.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(valueText, 1);
            grid.Children.Add(valueText);
        }
        var arrow = VectorIcon("M2,1 L8,7 L2,13", palette.Accent, 12, 18);
        arrow.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(arrow, 2);
        grid.Children.Add(arrow);
        button.Content = grid;
        button.Click += (_, _) => action();
        return button;
    }

    private Button ChoiceRow(string label, bool selected, Action action)
    {
        var button = new Button { Style = (Style)FindResource("RowButtonStyle") };
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var check = Text(selected ? "✓" : "", 17, palette.Accent, FontWeights.SemiBold, new Thickness(0, 0, 12, 0));
        check.Width = 15;
        check.VerticalAlignment = VerticalAlignment.Center;
        content.Children.Add(check);
        var labelText = Text(label, 15, weight: FontWeights.SemiBold);
        labelText.VerticalAlignment = VerticalAlignment.Center;
        content.Children.Add(labelText);
        button.Content = content;
        button.Click += (_, _) => action();
        return button;
    }

    private Button ChoiceHelpRow(string label, bool selected, string help, Action action)
    {
        var button = new Button { Style = (Style)FindResource("RowButtonStyle") };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(27) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
        var check = Text(selected ? "✓" : "", 17, palette.Accent, FontWeights.SemiBold);
        check.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(check);
        var labelText = Text(label, 15, weight: FontWeights.SemiBold);
        labelText.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(labelText, 1);
        grid.Children.Add(labelText);
        var helpText = Text("?", 16, palette.Accent, FontWeights.Bold);
        helpText.HorizontalAlignment = HorizontalAlignment.Center;
        helpText.VerticalAlignment = VerticalAlignment.Center;
        helpText.ToolTip = help;
        Grid.SetColumn(helpText, 2);
        grid.Children.Add(helpText);
        button.Content = grid;
        button.Click += (_, _) => action();
        return button;
    }

    private Border InformationRow(string value)
    {
        var text = Text(value, 15, weight: FontWeights.SemiBold);
        text.VerticalAlignment = VerticalAlignment.Center;
        return new Border
        {
            Background = Brush(palette.Surface),
            BorderBrush = (Brush)FindResource("OutlineBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(13),
            Height = 58,
            Padding = new Thickness(18, 0, 18, 0),
            Margin = new Thickness(0, 0, 0, 9),
            Child = text,
        };
    }

    private Border SelectionRow(string value)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(Text("✓", 17, palette.Accent, FontWeights.SemiBold, new Thickness(0, 0, 12, 0)));
        panel.Children.Add(Text(value, 15, weight: FontWeights.SemiBold));
        var row = InformationRow(value);
        row.Child = panel;
        return row;
    }

    private void AddBackHeader(Panel panel, string label, Action action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(VectorIcon("M14,1 L8,7 L14,13 M8,7 H20", palette.Accent, 20, 18));
        content.Children.Add(Text(label, 15, palette.Accent, FontWeights.SemiBold, new Thickness(10, 0, 0, 0)));
        var button = new Button
        {
            Style = (Style)FindResource("BackButtonStyle"),
            Width = double.NaN,
            Height = 58,
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(14, 0, 14, 0),
            Margin = new Thickness(0, 0, 0, 9),
            Content = content,
        };
        button.Click += (_, _) => action();
        panel.Children.Add(button);
    }

    private void ShowHome()
    {
        ResetPage(Screen.Home, true);
        ContentHost.RowDefinitions.Add(new RowDefinition());
        ContentHost.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var displayState = status.State;
        var label = displayState switch
        {
            "Ready" or "Disconnected" => "Connect",
            "Degraded" => "Reconnecting",
            _ => displayState,
        };
        var primary = new Button
        {
            Style = (Style)FindResource("PrimaryButtonStyle"),
            Content = Text(label, 16, displayState == "Connected" ? palette.Accent : TextColor, FontWeights.SemiBold),
            IsEnabled = !exitPending && (displayState is "Ready" or "Disconnected" or "Connected" or "Degraded" or "Error"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        primary.ApplyTemplate();
        SetPrimaryRing(primary, displayState);
        primary.Click += async (_, _) =>
        {
            if (status.State == "Error")
            {
                errorAcknowledged = true;
                status = ControllerStatus.Local("Ready", "ERROR_ACKNOWLEDGED");
                UpdateTrayCommands();
                ShowHome();
            }
            else if (status.State is "Ready" or "Disconnected")
                await RequestOperationAsync("connect");
            else if (status.State is "Connected" or "Degraded")
                await RequestOperationAsync("disconnect");
        };
        ContentHost.Children.Add(primary);

        var connection = new StackPanel();
        Grid.SetRow(connection, 1);
        // End the heading at the start of the cards' right-hand corner radius.
        var connectionLabel = Text("CONNECTION", 11, palette.Muted, FontWeights.SemiBold, new Thickness(0, 0, 14, 10));
        connectionLabel.HorizontalAlignment = HorizontalAlignment.Right;
        connection.Children.Add(connectionLabel);
        connection.Children.Add(RowButton("Server", "Aktau", () => ShowSelection(Screen.Server, "Server", "Aktau")));
        connection.Children.Add(RowButton("Protocol", "VLESS", () => ShowSelection(Screen.Transport, "Protocol", "VLESS")));
        connection.Children.Add(RowButton("Tunneling", "Full", () => ShowSelection(Screen.Routing, "Tunneling", "Full")));
        ContentHost.Children.Add(connection);
    }

    private void ShowSelection(Screen screen, string kind, string value)
    {
        ResetPage(screen, true);
        var panel = NewPagePanel();
        AddBackHeader(panel, kind, ShowHome);
        panel.Children.Add(SelectionRow(value));
    }

    private void ShowSettings()
    {
        ResetPage(Screen.Settings, false);
        var panel = NewPagePanel();
        panel.Children.Add(RowButton("Interface", themeChoice.ToString(), ShowInterface));
        panel.Children.Add(RowButton("Network", string.Empty, ShowNetwork));
        panel.Children.Add(RowButton("Diagnostics", string.Empty, ShowDiagnostics));
        panel.Children.Add(RowButton("About", ProductVersion, ShowAbout));
    }

    private void ShowInterface()
    {
        ResetPage(Screen.Interface, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Interface", ShowSettings);
        foreach (var choice in Enum.GetValues<ThemeChoice>())
        {
            panel.Children.Add(ChoiceRow(choice.ToString(), choice == themeChoice, () => { SetTheme(choice); ShowInterface(); }));
        }
    }

    private void ShowNetwork()
    {
        ResetPage(Screen.Network, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Network", ShowSettings);
        panel.Children.Add(RowButton("Credential", CredentialStore.Load() is null ? "Not configured" : "Configured", ShowCredential));
        panel.Children.Add(RowButton("Kill switch", appSettings.KillSwitchEnabled ? "On" : "Off", ShowKillSwitch));
    }

    private void ShowCredential()
    {
        ResetPage(Screen.Credential, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Credential", ShowNetwork);
        var activeRuntime = status.State is "Connecting" or "Connected" or "Degraded" or "Disconnecting";
        var draft = new CredentialDraft(CredentialStore.Load() ?? string.Empty);
        var synchronizingDraft = false;
        var input = new System.Windows.Controls.TextBox
        {
            Text = draft.Value,
            Style = (Style)FindResource("CredentialTextBoxStyle"),
            IsReadOnly = activeRuntime,
        };
        input.TextChanged += (_, _) =>
        {
            if (!synchronizingDraft) draft.Edit(input.Text);
        };
        void RenderDraft()
        {
            synchronizingDraft = true;
            input.Text = draft.Value;
            input.CaretIndex = input.Text.Length;
            synchronizingDraft = false;
        }
        panel.Children.Add(input);
        var actions = new Grid { Margin = new Thickness(0, 9, 0, 9), IsEnabled = !activeRuntime };
        actions.ColumnDefinitions.Add(new ColumnDefinition());
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        actions.ColumnDefinitions.Add(new ColumnDefinition());
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        actions.ColumnDefinitions.Add(new ColumnDefinition());
        var paste = CredentialAction("Paste", () =>
        {
            if (System.Windows.Clipboard.ContainsText()) draft.Edit(System.Windows.Clipboard.GetText());
            RenderDraft();
        });
        var clear = CredentialAction("Clear", () =>
        {
            if (!CredentialMutationAllowed()) { ShowCredential(); return; }
            draft.Clear(); RenderDraft();
        });
        var save = CredentialAction("Save", () =>
        {
            if (!CredentialMutationAllowed()) { ShowCredential(); return; }
            if (draft.ShouldDelete) { CredentialStore.Clear(); ShowNetwork(); }
            else if (CredentialStore.Save(draft.Value)) ShowNetwork();
            else input.BorderBrush = (Brush)FindResource("AccentBrush");
        });
        Grid.SetColumn(paste, 0); Grid.SetColumn(clear, 2); Grid.SetColumn(save, 4);
        actions.Children.Add(paste); actions.Children.Add(clear); actions.Children.Add(save);
        panel.Children.Add(actions);
        if (activeRuntime) panel.Children.Add(InformationRow("Disconnect before changing Credential."));
    }

    private bool CredentialMutationAllowed() => status.State is not ("Connecting" or "Connected" or "Degraded" or "Disconnecting");

    private Button CredentialAction(string label, Action action)
    {
        var button = new Button
        {
            Style = (Style)FindResource("RowButtonStyle"),
            Height = 58,
            Margin = new Thickness(0),
            Padding = new Thickness(8, 0, 8, 0),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = Text(label, 14, weight: FontWeights.SemiBold),
        };
        button.Click += (_, _) => action();
        return button;
    }

    private void ShowKillSwitch()
    {
        ResetPage(Screen.KillSwitch, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Kill switch", ShowNetwork);
        panel.Children.Add(ChoiceRow("On", appSettings.KillSwitchEnabled, () => SetKillSwitchEnabled(true)));
        panel.Children.Add(ChoiceRow("Off", !appSettings.KillSwitchEnabled, () => SetKillSwitchEnabled(false)));
        panel.Children.Add(RowButton("Mode", appSettings.KillSwitchMode.ToString(), ShowKillSwitchMode));
    }

    private void ShowKillSwitchMode()
    {
        ResetPage(Screen.KillSwitchMode, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Kill switch", ShowKillSwitch);
        panel.Children.Add(ChoiceHelpRow("Soft", appSettings.KillSwitchMode == KillSwitchModeChoice.Soft, "Protection remains while the Picky controller is running. It is released if the controller exits or crashes.", () => SetKillSwitchMode(KillSwitchModeChoice.Soft)));
        panel.Children.Add(ChoiceHelpRow("Strict", appSettings.KillSwitchMode == KillSwitchModeChoice.Strict, "Protection remains after the Picky GUI or controller exits and is removed by an intentional Disconnect or Picky recovery.", () => SetKillSwitchMode(KillSwitchModeChoice.Strict)));
    }

    private async void SetKillSwitchEnabled(bool enabled)
    {
        if (appSettings.KillSwitchEnabled == enabled) return;
        appSettings = appSettings with { KillSwitchEnabled = enabled };
        appSettings.Save();
        ShowKillSwitch();
        await ApplyKillSwitchConfigurationAsync();
    }

    private async void SetKillSwitchMode(KillSwitchModeChoice mode)
    {
        if (appSettings.KillSwitchMode == mode) return;
        appSettings = appSettings with { KillSwitchMode = mode };
        appSettings.Save();
        ShowKillSwitchMode();
        await ApplyKillSwitchConfigurationAsync();
    }

    private async Task ApplyKillSwitchConfigurationAsync()
    {
        if (status.State is not ("Connected" or "Degraded")) return;
        try
        {
            status = await controller.InvokeAsync("configure", true, appSettings);
        }
        catch (InvalidOperationException error) when (error.Message == "ELEVATION_CANCELLED")
        {
            status = ControllerStatus.Local("Error", "ELEVATION_CANCELLED");
        }
        catch
        {
            status = ControllerStatus.Local("Error", "KILL_SWITCH_CONFIGURE_FAILED");
        }
        PublishErrorEvent(status, true);
        UpdateTrayCommands();
    }

    private void PublishErrorEvent(ControllerStatus observed, bool isNewError)
    {
        if (observed.State != "Error") return;
        lastError = observed;
        if (!isNewError || IsVisible) return;
        RestoreFromTray();
        ShowHome();
    }

    private void ShowDiagnostics()
    {
        ResetPage(Screen.Diagnostics, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "Diagnostics", ShowSettings);
        panel.Children.Add(InformationRow($"State: {status.State}"));
        panel.Children.Add(InformationRow($"Code: {status.Code}"));
        if (!string.IsNullOrWhiteSpace(status.Context)) panel.Children.Add(InformationRow($"Context: {status.Context}"));
        if (lastError is not null)
        {
            panel.Children.Add(InformationRow($"Last error code: {lastError.Code}"));
            if (!string.IsNullOrWhiteSpace(lastError.Context)) panel.Children.Add(InformationRow($"Last error context: {lastError.Context}"));
        }
        panel.Children.Add(InformationRow($"Delivery: {status.Delivery}"));
    }

    private void ShowAbout()
    {
        ResetPage(Screen.About, false);
        var panel = NewPagePanel();
        AddBackHeader(panel, "About", ShowSettings);
        panel.Children.Add(InformationRow($"Version {ProductVersion}"));
    }

    private void SetPrimaryRing(Button primary, string state)
    {
        var baseRing = (System.Windows.Shapes.Path)primary.Template.FindName("PrimaryBaseRing", primary);
        var segmentRing = (System.Windows.Shapes.Path)primary.Template.FindName("PrimarySegmentRing", primary);
        if (state == "Connected")
        {
            baseRing.Stroke = Brush(palette.Accent);
            baseRing.StrokeThickness = 4.25;
            segmentRing.Visibility = Visibility.Collapsed;
            return;
        }
        baseRing.Stroke = (Brush)FindResource("BaseRingBrush");
        baseRing.StrokeThickness = 2.5;
        if (state is not ("Connecting" or "Disconnecting" or "Degraded"))
        {
            segmentRing.Visibility = Visibility.Collapsed;
            return;
        }
        segmentRing.Visibility = Visibility.Visible;
        segmentRing.StrokeThickness = 4.25;
        var direction = state == "Disconnecting" ? -1 : 1;
        ringTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(32) };
        ringTimer.Tick += (_, _) =>
        {
            var phase = direction * (Environment.TickCount64 % 1800) / 1800.0;
            segmentRing.Data = PrimarySegmentGeometry(phase);
        };
        ringTimer.Start();
    }

    private static PathGeometry PrimarySegmentGeometry(double startPhase)
    {
        var figure = new PathFigure { StartPoint = PrimaryRingPoint(startPhase) };
        var polyline = new PolyLineSegment();
        for (var index = 1; index <= 96; index++) polyline.Points.Add(PrimaryRingPoint(startPhase + .5 * index / 96.0));
        figure.Segments.Add(polyline);
        return new PathGeometry(new[] { figure });
    }

    private static Point PrimaryRingPoint(double phase)
    {
        var normalized = ((phase % 1) + 1) % 1;
        var scaled = normalized * 4;
        var quarter = Math.Min(3, (int)Math.Floor(scaled));
        var t = scaled - quarter;
        var points = quarter switch
        {
            0 => new[] { new Point(91, 2.5), new Point(166, 2.5), new Point(179.5, 12.5), new Point(179.5, 66) },
            1 => new[] { new Point(179.5, 66), new Point(179.5, 119.5), new Point(166, 129.5), new Point(91, 129.5) },
            2 => new[] { new Point(91, 129.5), new Point(16, 129.5), new Point(2.5, 119.5), new Point(2.5, 66) },
            _ => new[] { new Point(2.5, 66), new Point(2.5, 12.5), new Point(16, 2.5), new Point(91, 2.5) },
        };
        var inverse = 1 - t;
        return new Point(
            inverse * inverse * inverse * points[0].X + 3 * inverse * inverse * t * points[1].X + 3 * inverse * t * t * points[2].X + t * t * t * points[3].X,
            inverse * inverse * inverse * points[0].Y + 3 * inverse * inverse * t * points[1].Y + 3 * inverse * t * t * points[2].Y + t * t * t * points[3].Y);
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint loadFlags);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateIcon(IntPtr instance, int width, int height, byte planes, byte bitsPerPixel, byte[] andMask, byte[] xorMask);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    private void SetTaskbarIcon(uint? dpiOverride = null)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var iconPath = System.IO.Path.Combine(AppContext.BaseDirectory, "assets", "picky-taskbar.ico");
        const uint imageIcon = 1;
        const uint loadFromFile = 0x0010;
        const int smCxIcon = 11;
        const int smCxSmallIcon = 49;
        var dpi = dpiOverride.GetValueOrDefault(GetDpiForWindow(hwnd));
        if (dpi == 0) dpi = 96;
        var smallSize = GetSystemMetricsForDpi(smCxSmallIcon, dpi);
        var largeSize = GetSystemMetricsForDpi(smCxIcon, dpi);
        var largeIcon = LoadImage(IntPtr.Zero, iconPath, imageIcon, largeSize, largeSize, loadFromFile);
        var captionIcon = CreateTransparentCaptionIcon(smallSize);
        if (largeIcon == IntPtr.Zero || captionIcon == IntPtr.Zero)
        {
            if (largeIcon != IntPtr.Zero) _ = DestroyIcon(largeIcon);
            if (captionIcon != IntPtr.Zero) _ = DestroyIcon(captionIcon);
            throw new InvalidOperationException("Unable to load the PickyVPN taskbar icon.");
        }
        const int wmSetIcon = 0x0080;
        const int iconSmall = 0;
        const int iconBig = 1;
        var previousLargeIcon = taskbarLargeIcon;
        var previousCaptionIcon = transparentCaptionIcon;
        taskbarLargeIcon = largeIcon;
        transparentCaptionIcon = captionIcon;
        // Windows uses ICON_SMALL in the native caption and ICON_BIG for the taskbar/Alt-Tab identity.
        SendMessage(hwnd, wmSetIcon, new IntPtr(iconSmall), transparentCaptionIcon);
        SendMessage(hwnd, wmSetIcon, new IntPtr(iconBig), taskbarLargeIcon);
        if (previousLargeIcon != IntPtr.Zero) _ = DestroyIcon(previousLargeIcon);
        if (previousCaptionIcon != IntPtr.Zero) _ = DestroyIcon(previousCaptionIcon);
    }

    private static IntPtr CreateTransparentCaptionIcon(int size)
    {
        var scanlineBytes = ((size + 31) / 32) * 4;
        var andMask = new byte[scanlineBytes * size];
        Array.Fill(andMask, byte.MaxValue);
        var xorMask = new byte[scanlineBytes * size];
        return CreateIcon(IntPtr.Zero, size, size, 1, 1, andMask, xorMask);
    }

    private void ReleaseTaskbarIcons()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        const int wmSetIcon = 0x0080;
        const int iconSmall = 0;
        const int iconBig = 1;
        if (hwnd != IntPtr.Zero)
        {
            SendMessage(hwnd, wmSetIcon, new IntPtr(iconSmall), IntPtr.Zero);
            SendMessage(hwnd, wmSetIcon, new IntPtr(iconBig), IntPtr.Zero);
        }
        if (taskbarLargeIcon != IntPtr.Zero) _ = DestroyIcon(taskbarLargeIcon);
        if (transparentCaptionIcon != IntPtr.Zero) _ = DestroyIcon(transparentCaptionIcon);
        taskbarLargeIcon = IntPtr.Zero;
        transparentCaptionIcon = IntPtr.Zero;
    }
}
