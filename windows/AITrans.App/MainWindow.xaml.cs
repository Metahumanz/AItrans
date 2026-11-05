using System.Collections.ObjectModel;
using System.Diagnostics;
using AITrans.Core;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace AITrans.App;

public sealed partial class MainWindow : Window
{
    private readonly SettingsStore _settingsStore = new();
    private readonly ProviderStore _providerStore;
    private readonly ObservableCollection<FileItem> _files = [];
    private readonly ObservableCollection<ProviderItem> _providers = [];

    private CancellationTokenSource? _cts;
    private bool _running;
    private bool _initializing = true;

    public MainWindow()
    {
        InitializeComponent();

        _providerStore = new ProviderStore(new DpapiSecretStore(AppPaths.SecretsFile));

        ConfigureWindow();

        try
        {
            AppPaths.Prepare();
        }
        catch (Exception)
        {
            // 目录创建失败时后续保存会再次报错，这里不阻塞启动。
        }

        try
        {
            _settingsStore.Load(AppPaths.SettingsFile);
        }
        catch (AITransException)
        {
            // 设置损坏时使用默认值。
        }

        try
        {
            _providerStore.Load(AppPaths.ProvidersFile);
        }
        catch (AITransException)
        {
            // 配置损坏时从空列表开始。
        }

        FileList.ItemsSource = _files;
        ProviderList.ItemsSource = _providers;

        ApplySettingsToUi();
        RefreshProviders();
        RefreshFiles();

        VersionText.Text = $"版本 {GetVersion()}";
        Closed += (_, _) => SaveSettings();
        _initializing = false;
    }

    // ---------------------------------------------------------------- 初始化

    private void ConfigureWindow()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);

        if (MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop();
            Nav.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        else
        {
            Root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        }

        // AppWindow.Resize 用的是物理像素，按当前 DPI 换算成逻辑尺寸，再夹到工作区内。
        var scale = GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)(1180 * scale), workArea.Width - 80);
        var height = Math.Min((int)(800 * scale), workArea.Height - 80);
        AppWindow.Resize(new SizeInt32(width, height));
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private static string GetVersion()
    {
        var version = typeof(MainWindow).Assembly.GetName().Version;
        return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
    }

    private void ApplySettingsToUi()
    {
        var settings = _settingsStore.Settings;
        EngineCombo.SelectedIndex = settings.Backend == Engine.api ? 0 : 1;
        ModelBox.Text = settings.ApiModel;
        LanguageCombo.SelectedIndex = (int)settings.Lang;
        TranslateSwitch.IsOn = settings.Translate;
        PolishSwitch.IsOn = settings.Polish;
        ForceSwitch.IsOn = settings.Force;
        OutputCombo.SelectedIndex = settings.OutputMode switch
        {
            OutputMode.source => 0,
            OutputMode.output => 1,
            _ => 2,
        };
        SuffixBox.Text = settings.Suffix;
        CustomDirBox.Text = settings.CustomDir;
        WorkersBox.Value = settings.Backend == Engine.ollama ? settings.OllamaWorkers : settings.ApiWorkers;
        RetriesBox.Value = settings.Backend == Engine.ollama ? settings.OllamaRetries : settings.ApiRetries;
        CustomDirPanel.Visibility = settings.OutputMode == OutputMode.custom ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SaveSettings()
    {
        var settings = _settingsStore.Settings;
        settings.Backend = EngineCombo.SelectedIndex == 1 ? Engine.ollama : Engine.api;
        settings.ApiModel = ModelBox.Text.Trim();
        settings.Lang = (Language)Math.Max(0, LanguageCombo.SelectedIndex);
        settings.Translate = TranslateSwitch.IsOn;
        settings.Polish = PolishSwitch.IsOn;
        settings.Force = ForceSwitch.IsOn;
        settings.OutputMode = OutputCombo.SelectedIndex switch
        {
            1 => OutputMode.output,
            2 => OutputMode.custom,
            _ => OutputMode.source,
        };
        settings.Suffix = SuffixBox.Text;
        settings.CustomDir = CustomDirBox.Text;
        var workers = double.IsNaN(WorkersBox.Value) ? 20 : (int)WorkersBox.Value;
        var retries = double.IsNaN(RetriesBox.Value) ? 2 : (int)RetriesBox.Value;
        if (settings.Backend == Engine.ollama)
        {
            settings.OllamaWorkers = workers;
            settings.OllamaRetries = retries;
        }
        else
        {
            settings.ApiWorkers = workers;
            settings.ApiRetries = retries;
        }

        try
        {
            _settingsStore.Save(AppPaths.SettingsFile);
        }
        catch (Exception)
        {
            // 保存失败不阻塞关闭。
        }
    }

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItemContainer as NavigationViewItem)?.Tag as string;
        TasksPanel.Visibility = tag == "tasks" ? Visibility.Visible : Visibility.Collapsed;
        ProvidersPanel.Visibility = tag == "providers" ? Visibility.Visible : Visibility.Collapsed;
        AboutPanel.Visibility = tag == "about" ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---------------------------------------------------------------- 文件

    private void AddFile(string path)
    {
        if (!string.Equals(Path.GetExtension(path), ".srt", StringComparison.OrdinalIgnoreCase)) return;
        var full = Path.GetFullPath(path);
        if (_files.Any(existing => string.Equals(existing.Path, full, StringComparison.OrdinalIgnoreCase))) return;
        _files.Add(new FileItem(full));
    }

    private void AddFolder(string path)
    {
        if (!Directory.Exists(path)) return;
        var candidates = Directory.EnumerateFiles(path)
            .Where(file => string.Equals(Path.GetExtension(file), ".srt", StringComparison.OrdinalIgnoreCase))
            .OrderBy(File.GetLastWriteTimeUtc);
        foreach (var candidate in candidates) AddFile(candidate);
    }

    private void RefreshFiles()
    {
        EmptyState.Visibility = _files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_running) return;
        StatusLabel.Text = _files.Count == 0
            ? "拖入 .srt 文件或文件夹开始"
            : $"已添加 {_files.Count} 个文件";
    }

    private async void OnAddFiles(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".srt");

        var files = await picker.PickMultipleFilesAsync();
        if (files is null) return;
        foreach (var file in files) AddFile(file.Path);
        RefreshFiles();
    }

    private async void OnAddFolder(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");

        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        AddFolder(folder.Path);
        RefreshFiles();
    }

    private void OnClearFiles(object sender, RoutedEventArgs e)
    {
        if (_running) return;
        _files.Clear();
        RefreshFiles();
    }

    private void OnAddPath(object sender, RoutedEventArgs e) => AddPathFromBox();

    private void OnPathKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        AddPathFromBox();
        e.Handled = true;
    }

    private void AddPathFromBox()
    {
        var raw = (PathBox.Text ?? "").Trim().Trim('"');
        if (raw.Length == 0) return;

        var expanded = Environment.ExpandEnvironmentVariables(raw);
        if (!Path.IsPathRooted(expanded))
        {
            _ = ShowMessageAsync("请填写完整路径（例如 C:\\Movies\\a.srt）。");
            return;
        }
        if (!File.Exists(expanded) && !Directory.Exists(expanded))
        {
            _ = ShowMessageAsync($"路径不存在：{expanded}");
            return;
        }

        if (Directory.Exists(expanded)) AddFolder(expanded);
        else AddFile(expanded);

        PathBox.Text = "";
        RefreshFiles();
    }

    private void OnFileListDragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "添加到列表";
    }

    private async void OnFileListDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        foreach (var item in items)
        {
            switch (item)
            {
                case StorageFolder folder:
                    AddFolder(folder.Path);
                    break;
                case StorageFile file:
                    AddFile(file.Path);
                    break;
            }
        }
        RefreshFiles();
    }

    private void OnEngineChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        var ollama = EngineCombo.SelectedIndex == 1;
        WorkersBox.Value = ollama ? _settingsStore.Settings.OllamaWorkers : _settingsStore.Settings.ApiWorkers;
        RetriesBox.Value = ollama ? _settingsStore.Settings.OllamaRetries : _settingsStore.Settings.ApiRetries;
    }

    private void OnOutputModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        CustomDirPanel.Visibility = OutputCombo.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnChooseCustomDir(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null) CustomDirBox.Text = folder.Path;
    }

    // ---------------------------------------------------------------- 任务

    private async void OnStart(object sender, RoutedEventArgs e)
    {
        if (_running)
        {
            _cts?.Cancel();
            return;
        }

        if (_files.Count == 0)
        {
            await ShowMessageAsync("请先添加字幕文件。");
            return;
        }

        SaveSettings();
        var settings = _settingsStore.Settings;
        var usesOllama = settings.Backend == Engine.ollama;

        var provider = _providerStore.ActiveProvider;
        if (!usesOllama && provider is null)
        {
            await ShowMessageAsync("请先在「提供商」里添加并启用一个提供商。");
            return;
        }

        var model = usesOllama
            ? settings.OllamaModel.Trim()
            : (string.IsNullOrWhiteSpace(ModelBox.Text) ? provider!.Model : ModelBox.Text.Trim());
        if (string.IsNullOrWhiteSpace(model))
        {
            await ShowMessageAsync(usesOllama ? "请填写 Ollama 模型名称。" : "请填写模型名称。");
            return;
        }

        var customDirectory = settings.OutputMode == OutputMode.custom && !string.IsNullOrWhiteSpace(settings.CustomDir)
            ? settings.CustomDir
            : null;

        IChatCompleter client = usesOllama
            ? new OllamaClient(model, policy: new RetryPolicy(settings.OllamaRetries))
            : new ChatClient(
                provider!.BaseUrl,
                provider!.ApiKey,
                model,
                policy: new RetryPolicy(settings.ApiRetries));
        var runner = new JobRunner(new Translator(client));

        _cts = new CancellationTokenSource();
        _running = true;
        foreach (var item in _files) item.Result = null;
        StartButtonText.Text = "取消";
        StartIcon.Glyph = "\uE711";
        JobProgressBar.IsIndeterminate = false;
        JobProgressBar.Value = 0;
        StatusLabel.Text = "准备开始…";

        var progress = new Progress<JobProgress>(update =>
        {
            JobProgressBar.Value = update.Total == 0 ? 0 : update.Completed * 100.0 / update.Total;
            StatusLabel.Text = string.IsNullOrEmpty(update.CurrentName)
                ? $"已完成 {update.Completed}/{update.Total}"
                : $"正在处理 {update.CurrentName}（{update.Completed}/{update.Total}）";
        });

        try
        {
            if (usesOllama)
            {
                JobProgressBar.IsIndeterminate = true;
                StatusLabel.Text = "正在检查本地 Ollama…";
                await OllamaService.EnsureRunningAsync();
                await OllamaService.EnsureModelAsync(settings.OllamaModel);
                JobProgressBar.IsIndeterminate = false;
            }

            var results = await runner.RunAsync(
                _files.Select(item => item.Path).ToList(),
                settings,
                AppPaths.DefaultOutputDirectory,
                customDirectory,
                progress,
                cancellationToken: _cts.Token);

            foreach (var result in results)
            {
                var item = _files.FirstOrDefault(file =>
                    string.Equals(Path.GetFileName(file.Path), result.Name, StringComparison.OrdinalIgnoreCase));
                if (item is not null) item.Result = result;
            }

            var ok = results.Count(result => result.Status == FileResult.StatusKind.success);
            var skipped = results.Count(result => result.Status == FileResult.StatusKind.skipped);
            var failed = results.Count(result => result.Status == FileResult.StatusKind.failed);
            JobProgressBar.Value = 100;
            StatusLabel.Text = $"完成：成功 {ok}，跳过 {skipped}，失败 {failed}";
            if (failed > 0) await ShowMessageAsync($"有 {failed} 个文件失败，详情见列表。");
        }
        catch (OperationCanceledException)
        {
            StatusLabel.Text = "已取消";
        }
        catch (Exception error)
        {
            StatusLabel.Text = "已停止";
            await ShowMessageAsync(error.Message);
        }
        finally
        {
            _running = false;
            StartButtonText.Text = "开始翻译";
            StartIcon.Glyph = "\uE768";
            JobProgressBar.IsIndeterminate = false;
            _cts?.Dispose();
            _cts = null;
        }
    }

    // ---------------------------------------------------------------- 提供商

    private void RefreshProviders()
    {
        _providers.Clear();
        foreach (var provider in _providerStore.Providers)
        {
            _providers.Add(new ProviderItem(provider, provider.Id == _providerStore.ActiveId));
        }
        ProviderEmptyState.Visibility = _providers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private ProviderItem? SelectedProvider =>
        ProviderList.SelectedItem as ProviderItem;

    private async void OnProviderAdd(object sender, RoutedEventArgs e) => await ShowProviderDialogAsync(null);

    private async void OnProviderEdit(object sender, RoutedEventArgs e)
    {
        if (SelectedProvider is null)
        {
            await ShowMessageAsync("请先在列表里选择一个提供商。");
            return;
        }
        await ShowProviderDialogAsync(SelectedProvider);
    }

    private async void OnProviderSetActive(object sender, RoutedEventArgs e)
    {
        if (SelectedProvider is null)
        {
            await ShowMessageAsync("请先在列表里选择一个提供商。");
            return;
        }
        try
        {
            _providerStore.SetActive(SelectedProvider.Provider.Id);
            _providerStore.Save(AppPaths.ProvidersFile);
            RefreshProviders();
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
    }

    private async void OnProviderTest(object sender, RoutedEventArgs e)
    {
        if (SelectedProvider is null)
        {
            await ShowMessageAsync("请先在列表里选择一个提供商。");
            return;
        }
        StatusLabel.Text = "正在测试连接…";
        var message = await TestProviderAsync(SelectedProvider.Provider.BaseUrl, SelectedProvider.Provider.ApiKey);
        StatusLabel.Text = message;
        await ShowMessageAsync(message);
    }

    private async void OnProviderDelete(object sender, RoutedEventArgs e)
    {
        if (SelectedProvider is null)
        {
            await ShowMessageAsync("请先在列表里选择一个提供商。");
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "删除提供商",
            Content = new TextBlock
            {
                Text = $"确定删除「{SelectedProvider.Provider.Name}」？密钥会一并移除。",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        _providerStore.Delete(SelectedProvider.Provider.Id);
        _providerStore.Save(AppPaths.ProvidersFile);
        RefreshProviders();
    }

    private async void OnProviderImport(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".json");
        picker.FileTypeFilter.Add(".env");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        try
        {
            var count = _providerStore.ImportLegacy(file.Path, null);
            _providerStore.Save(AppPaths.ProvidersFile);
            RefreshProviders();
            await ShowMessageAsync(count > 0 ? $"已导入 {count} 个提供商。" : "没有找到可导入的配置。");
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
    }

    private async Task ShowProviderDialogAsync(ProviderItem? existing)
    {
        var editing = existing?.Provider.Clone();

        var presetCombo = new ComboBox
        {
            Header = "从预设开始",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Margin = new Thickness(0, 0, 0, 12),
            Visibility = existing is null ? Visibility.Visible : Visibility.Collapsed,
        };
        foreach (var preset in Spec.Presets) presetCombo.Items.Add(preset.Name);

        var nameBox = new TextBox { Header = "名称", Margin = new Thickness(0, 0, 0, 12), Text = editing?.Name ?? "" };
        var urlBox = new TextBox { Header = "接口地址", Margin = new Thickness(0, 0, 0, 12), Text = editing?.BaseUrl ?? "" };
        var modelBox = new TextBox { Header = "模型", Margin = new Thickness(0, 0, 0, 12), Text = editing?.Model ?? "" };
        var keyBox = new PasswordBox { Header = "API Key", Margin = new Thickness(0, 0, 0, 12), Password = editing?.ApiKey ?? "" };
        var testText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = UiBrush.Get("TextFillColorSecondaryBrush", Microsoft.UI.Colors.Gray),
            Margin = new Thickness(0, 8, 0, 0),
        };

        var testButton = new Button { Content = "测试连接" };
        testButton.Click += async (_, _) =>
        {
            testText.Text = "正在测试…";
            testText.Text = await TestProviderAsync(urlBox.Text.Trim(), keyBox.Password);
        };

        presetCombo.SelectionChanged += (_, _) =>
        {
            if (presetCombo.SelectedIndex < 0 || presetCombo.SelectedIndex >= Spec.Presets.Length) return;
            var preset = Spec.Presets[presetCombo.SelectedIndex];
            nameBox.Text = preset.Name;
            urlBox.Text = preset.BaseUrl;
            modelBox.Text = preset.Model;
        };

        var content = new StackPanel { MinWidth = 420, Spacing = 0 };
        content.Children.Add(presetCombo);
        content.Children.Add(nameBox);
        content.Children.Add(urlBox);
        content.Children.Add(modelBox);
        content.Children.Add(keyBox);
        content.Children.Add(testButton);
        content.Children.Add(testText);

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = existing is null ? "添加提供商" : "编辑提供商",
            Content = content,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        try
        {
            _providerStore.Upsert(new Provider
            {
                Id = editing?.Id ?? "",
                Name = nameBox.Text,
                BaseUrl = urlBox.Text,
                Model = modelBox.Text,
                ApiKey = keyBox.Password,
                RequiresKey = true,
            }, activate: true);
            _providerStore.Save(AppPaths.ProvidersFile);
            RefreshProviders();
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
    }

    private static async Task<string> TestProviderAsync(string baseUrl, string apiKey)
    {
        if (string.IsNullOrWhiteSpace(baseUrl)) return "请填写接口地址。";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
            using var request = new HttpRequestMessage(HttpMethod.Get, baseUrl.TrimEnd('/') + "/models");
            request.Headers.Add("Accept", "application/json");
            if (!string.IsNullOrEmpty(apiKey))
            {
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey);
            }
            using var response = await http.SendAsync(request);
            var status = (int)response.StatusCode;
            return status switch
            {
                200 => "连接成功（HTTP 200）",
                401 or 403 => $"鉴权失败（HTTP {status}），请检查 API Key",
                404 => "可以访问，但没有 /models 接口（HTTP 404）",
                _ => $"HTTP {status}",
            };
        }
        catch (Exception error)
        {
            return $"连接失败：{error.Message}";
        }
    }

    // ---------------------------------------------------------------- 更新与杂项

    private async void OnCheckUpdates(object sender, RoutedEventArgs e)
    {
        var checker = new UpdateChecker { CurrentVersion = GetVersion() };
        try
        {
            var info = await checker.CheckAsync();
            if (info is null)
            {
                await ShowMessageAsync("已是最新版本。");
                return;
            }

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"发现新版本 {info.Version}",
                Content = new ScrollViewer
                {
                    MaxHeight = 320,
                    Content = new TextBlock
                    {
                        Text = string.IsNullOrWhiteSpace(info.Notes) ? "该版本没有填写更新说明。" : info.Notes,
                        TextWrapping = TextWrapping.Wrap,
                    },
                },
                PrimaryButtonText = "下载更新",
                SecondaryButtonText = "打开下载页",
                CloseButtonText = "稍后",
                DefaultButton = ContentDialogButton.Primary,
            };

            var choice = await dialog.ShowAsync();
            if (choice == ContentDialogResult.Primary)
            {
                try
                {
                    StatusLabel.Text = "正在下载更新…";
                    var path = await UpdateDownloader.DownloadAsync(info);
                    StatusLabel.Text = "更新已下载";
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "explorer.exe",
                        Arguments = $"/select,\"{path}\"",
                        UseShellExecute = true,
                    });
                    await ShowMessageAsync(UpdateDownloader.InstallHint);
                }
                catch (Exception error)
                {
                    await ShowMessageAsync(error.Message);
                }
            }
            else if (choice == ContentDialogResult.Secondary)
            {
                await Launcher.LaunchUriAsync(new Uri(info.PageUrl));
            }
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
    }

    private async void OnOpenOutput(object sender, RoutedEventArgs e)
    {
        try
        {
            AppPaths.Prepare();
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = AppPaths.DefaultOutputDirectory,
                UseShellExecute = true,
            });
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
        await Task.CompletedTask;
    }

    private async void OnOpenDataFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            AppPaths.Prepare();
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = AppPaths.SupportDirectory,
                UseShellExecute = true,
            });
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
        await Task.CompletedTask;
    }

    private async Task ShowMessageAsync(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = "提示",
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "好",
        };
        await dialog.ShowAsync();
    }
}
