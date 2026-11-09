using System.Collections.ObjectModel;
using System.Diagnostics;
using AITrans.Core;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
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
    private bool _paused;
    private PauseGate? _pauseGate;
    private bool _initializing = true;
    private UpdateInfo? _updateInfo;
    private string? _startupWarning;
    private CueProgress? _activeCueProgress;
    private string _currentFileName = "";
    private int _currentFileCompleted;
    private int _currentFileTotal;

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
        catch (Exception error)
        {
            // 配置损坏时从空列表开始，但把原因留到窗口显示后再告诉用户。
            _startupWarning = $"读取提供商配置失败：{error.Message}";
        }

        try
        {
            // 旧版 providers.json 里的明文 key 在载入后立刻迁移，避免只翻译不改配置的用户一直留着明文。
            _providerStore.MigratePlaintextKeys(AppPaths.ProvidersFile);
        }
        catch (Exception error)
        {
            _startupWarning ??= $"迁移旧版明文 API Key 失败：{error.Message}";
        }

        FileList.ItemsSource = _files;
        ProviderList.ItemsSource = _providers;

        ApplySettingsToUi();
        RefreshProviders();
        RefreshFiles();

        VersionText.Text = $"版本 {GetVersion()}";
        Closed += (_, _) => SaveSettings();
        _initializing = false;

        // 等首帧排好版再放动画，否则窗口还没显示就已经播完了。
        DispatcherQueue.TryEnqueue(() => ShowPage("tasks", animate: true));
        _ = CheckUpdatesQuietlyAsync();

        if (_startupWarning is not null)
        {
            DispatcherQueue.TryEnqueue(async () =>
            {
                try
                {
                    await ShowMessageAsync(_startupWarning);
                }
                catch (Exception)
                {
                    // 启动阶段弹窗失败不致命。
                }
            });
        }
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
        AutoCheckToggle.IsOn = settings.AutoCheckUpdates;
        DownloadDirBox.Text = settings.DownloadDir;
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
        settings.AutoCheckUpdates = AutoCheckToggle.IsOn;
        settings.DownloadDir = DownloadDirBox.Text.Trim();
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
        if (_initializing) return;
        var tag = (args.SelectedItemContainer as NavigationViewItem)?.Tag as string ?? "tasks";
        ShowPage(tag, animate: true);
    }

    private void ShowPage(string tag, bool animate)
    {
        TasksPanel.Visibility = tag == "tasks" ? Visibility.Visible : Visibility.Collapsed;
        ProvidersPanel.Visibility = tag == "providers" ? Visibility.Visible : Visibility.Collapsed;
        AboutPanel.Visibility = tag == "about" ? Visibility.Visible : Visibility.Collapsed;

        if (!animate) return;

        switch (tag)
        {
            case "providers":
                AnimateIn(ProvidersHeader, ProviderActions, ProvidersCard);
                break;
            case "about":
                AnimateIn(AboutHeader, AboutCards);
                break;
            default:
                AnimateIn(TasksHeader, FilesCard, TranslateCard, OutputCard, ConcurrencyCard, TasksFooter);
                break;
        }
    }

    // ---------------------------------------------------------------- 动效

    private static readonly TimeSpan PageAnimationDuration = TimeSpan.FromMilliseconds(180);

    /// <summary>让一组元素依次淡入并轻微上移，形成瀑布感。</summary>
    private static void AnimateIn(params FrameworkElement[] elements)
    {
        for (var index = 0; index < elements.Length; index++)
        {
            AnimateIn(elements[index], index * 35);
        }
    }

    private static void AnimateIn(FrameworkElement element, int delayMs)
    {
        if (element is null) return;

        if (element.RenderTransform is not CompositeTransform transform)
        {
            transform = new CompositeTransform();
            element.RenderTransform = transform;
        }

        element.Opacity = 0;
        transform.TranslateY = 16;

        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var begin = TimeSpan.FromMilliseconds(delayMs);

        var fade = new DoubleAnimation
        {
            To = 1,
            Duration = new Duration(PageAnimationDuration),
            BeginTime = begin,
            EasingFunction = ease,
        };
        Storyboard.SetTarget(fade, element);
        Storyboard.SetTargetProperty(fade, "Opacity");

        var slide = new DoubleAnimation
        {
            To = 0,
            Duration = new Duration(PageAnimationDuration),
            BeginTime = begin,
            EasingFunction = ease,
        };
        Storyboard.SetTarget(slide, transform);
        Storyboard.SetTargetProperty(slide, "TranslateY");

        var storyboard = new Storyboard();
        storyboard.Children.Add(fade);
        storyboard.Children.Add(slide);
        storyboard.Begin();
    }

    /// <summary>空状态出现时淡入，避免突然蹦出来。</summary>
    private static void FadeIn(UIElement element)
    {
        element.Opacity = 0;

        var fade = new DoubleAnimation
        {
            To = 1,
            Duration = new Duration(TimeSpan.FromMilliseconds(160)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(fade, element);
        Storyboard.SetTargetProperty(fade, "Opacity");

        var storyboard = new Storyboard();
        storyboard.Children.Add(fade);
        storyboard.Begin();
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
        var empty = _files.Count == 0;
        EmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        if (empty) FadeIn(EmptyState);
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

    private async void OnChooseDownloadDir(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
        {
            DownloadDirBox.Text = folder.Path;
            SaveSettings();
        }
    }

    // ---------------------------------------------------------------- 任务

    private async void OnStart(object sender, RoutedEventArgs e)
    {
        if (_running) return;

        if (_files.Count == 0)
        {
            await ShowMessageAsync("请先添加字幕文件。");
            return;
        }

        SaveSettings();
        var settings = _settingsStore.Settings;
        var usesOllama = settings.Backend == Engine.ollama;

        var provider = _providerStore.ActiveProvider;
        if (!usesOllama)
        {
            if (provider is null)
            {
                await ShowMessageAsync("请先在「提供商」里添加并启用一个提供商。");
                return;
            }

            // 内存里的 key 可能是空的（例如上次保存时留空），先按需从加密存储补齐再判断。
            try
            {
                provider = _providerStore.Hydrate(provider);
            }
            catch (Exception error)
            {
                await ShowMessageAsync($"读取 API Key 失败：{error.Message}");
                return;
            }

            if (provider.RequiresKey && string.IsNullOrEmpty(provider.ApiKey))
            {
                await ShowMessageAsync("该提供商还没有 API Key。密钥保存在本地加密文件，请在「提供商」里填写。");
                return;
            }
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

        var gate = new PauseGate();
        _pauseGate = gate;
        _paused = false;
        _cts = new CancellationTokenSource();
        _running = true;
        foreach (var item in _files) item.Result = null;
        StartButton.IsEnabled = false;
        PauseButton.Visibility = Visibility.Visible;
        PauseButtonText.Text = "暂停";
        PauseIcon.Glyph = "\uE769";
        CancelButton.Visibility = Visibility.Visible;
        JobProgressBar.IsIndeterminate = false;
        JobProgressBar.Value = 0;
        StatusLabel.Text = "准备开始…";
        ClearCueProgress();
        _currentFileName = "";
        _currentFileCompleted = 0;
        _currentFileTotal = 0;

        var progress = new Progress<JobProgress>(update =>
        {
            JobProgressBar.Value = update.Total == 0 ? 0 : update.Completed * 100.0 / update.Total;
            _currentFileName = update.CurrentName;
            _currentFileCompleted = update.Completed;
            _currentFileTotal = update.Total;
            // 文件事件和段事件是两条异步回调，顺序不保证。
            // 如果段进度已经属于这个文件，就保留它，避免刚出现的进度条被清掉。
            if (_activeCueProgress?.FileName != update.CurrentName)
            {
                ClearCueProgress();
            }
            if (_paused) return;
            StatusLabel.Text = string.IsNullOrEmpty(update.CurrentName)
                ? $"已完成 {update.Completed}/{update.Total}"
                : _activeCueProgress is { } cue && cue.FileName == update.CurrentName
                    ? $"正在{cue.Stage.DisplayName()} {update.CurrentName}（{update.Completed}/{update.Total}）"
                    : $"正在处理 {update.CurrentName}（{update.Completed}/{update.Total}）";
        });

        var cueProgress = new Progress<CueProgress>(update =>
        {
            _activeCueProgress = update;
            if (!string.IsNullOrEmpty(update.FileName)) _currentFileName = update.FileName;
            ShowCueProgress(update);
            if (_paused) return;
            if (!string.IsNullOrEmpty(_currentFileName))
            {
                var counts = _currentFileTotal > 0
                    ? $"（{_currentFileCompleted}/{_currentFileTotal}）"
                    : "";
                StatusLabel.Text = $"正在{update.Stage.DisplayName()} {_currentFileName}{counts}";
            }
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
                pauseGate: gate,
                fileProgress: progress,
                cueProgress: cueProgress,
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
            _paused = false;
            _pauseGate = null;
            StartButton.IsEnabled = true;
            PauseButton.Visibility = Visibility.Collapsed;
            CancelButton.Visibility = Visibility.Collapsed;
            JobProgressBar.IsIndeterminate = false;
            ClearCueProgress();
            _currentFileName = "";
            _currentFileCompleted = 0;
            _currentFileTotal = 0;
            _cts?.Dispose();
            _cts = null;
        }
    }

    /// <summary>暂停只在波次之间生效：已发出的请求会跑完，继续后从下一波接着处理。</summary>
    private void OnPause(object sender, RoutedEventArgs e)
    {
        if (!_running || _pauseGate is null) return;

        if (_paused)
        {
            _paused = false;
            _pauseGate.Resume();
            PauseButtonText.Text = "暂停";
            PauseIcon.Glyph = "\uE769";
            StatusLabel.Text = "继续处理…";
        }
        else
        {
            _paused = true;
            _pauseGate.Pause();
            PauseButtonText.Text = "继续";
            PauseIcon.Glyph = "\uE768";
            StatusLabel.Text = "已暂停";
        }
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        if (!_running) return;

        StatusLabel.Text = "正在取消…";
        _paused = false;
        _cts?.Cancel();
        // 取消时把暂停中的等待一起唤醒，让任务走到取消分支。
        _pauseGate?.Resume();
    }

    /// <summary>显示当前文件的翻译 / 润色段级进度，对应 legacy 的 tqdm。</summary>
    private void ShowCueProgress(CueProgress update)
    {
        CueProgressRow.Visibility = Visibility.Visible;
        CueStageLabel.Text = update.Stage.DisplayName();
        CueProgressBar.Value = update.Fraction * 100;
        CueCountLabel.Text = $"{update.Completed}/{update.Total} 段";
        CueStatsLabel.Text = $"成功 {update.SuccessCount} · 失败 {update.ErrorCount}";
        CueStatsLabel.Foreground = update.ErrorCount > 0
            ? UiBrush.Get("SystemFillColorCriticalBrush", Microsoft.UI.Colors.IndianRed)
            : UiBrush.Get("TextFillColorSecondaryBrush", Microsoft.UI.Colors.Gray);
    }

    private void ClearCueProgress()
    {
        _activeCueProgress = null;
        CueProgressRow.Visibility = Visibility.Collapsed;
        CueProgressBar.Value = 0;
        CueStageLabel.Text = "";
        CueCountLabel.Text = "";
        CueStatsLabel.Text = "";
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
        if (_providers.Count == 0) FadeIn(ProviderEmptyState);
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

        Provider provider;
        try
        {
            provider = _providerStore.Hydrate(SelectedProvider.Provider);
        }
        catch (Exception error)
        {
            StatusLabel.Text = "测试连接失败";
            await ShowMessageAsync($"读取 API Key 失败：{error.Message}");
            return;
        }

        var message = await TestProviderAsync(provider.BaseUrl, provider.ApiKey);
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

        try
        {
            _providerStore.Delete(SelectedProvider.Provider.Id);
            _providerStore.Save(AppPaths.ProvidersFile);
            RefreshProviders();
        }
        catch (AITransException error)
        {
            await ShowMessageAsync($"{error.Message}\n\n如果密钥文件已损坏，可手动删除 {AppPaths.SecretsFile} 后重试。");
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
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
        // 编辑前先补齐密钥：内存里可能是空 key（例如上次保存时留空），从加密存储读回来再填表单，
        // 否则保存时会把这个空值当成「保留」，用户就再也看不到已存的 key 了。
        Provider? editing = null;
        string? hydrateError = null;
        if (existing is not null)
        {
            try
            {
                editing = _providerStore.Hydrate(existing.Provider).Clone();
            }
            catch (Exception error)
            {
                // 读不到也照常打开表单，让用户能清除或重填，而不是卡死在这里。
                editing = existing.Provider.Clone();
                hydrateError = $"读取已保存的 API Key 失败：{error.Message}";
            }
        }

        // 预设可能不需要 Key（例如本地 Ollama）；编辑已有提供商时沿用原值，不要一律写成 true。
        var requiresKey = editing?.RequiresKey ?? true;

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
        var requiresKeyBox = new CheckBox
        {
            Content = "需要 API Key",
            IsChecked = requiresKey,
            Margin = new Thickness(0, 0, 0, 12),
        };
        var testText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = UiBrush.Get("TextFillColorSecondaryBrush", Microsoft.UI.Colors.Gray),
            Margin = new Thickness(0, 8, 0, 0),
        };
        if (hydrateError is not null) testText.Text = hydrateError;

        var testButton = new Button { Content = "测试连接" };
        testButton.Click += async (_, _) =>
        {
            testText.Text = "正在测试…";
            testText.Text = await TestProviderAsync(urlBox.Text.Trim(), keyBox.Password);
        };

        // 清空密钥：真正删除延后到「保存」，取消对话框不会误删。
        var clearKeyRequested = false;
        var clearKeyButton = new Button
        {
            Content = "清除已保存的密钥",
            IsEnabled = editing is not null && !string.IsNullOrEmpty(editing.ApiKey),
        };
        clearKeyButton.Click += (_, _) =>
        {
            clearKeyRequested = true;
            keyBox.Password = "";
            clearKeyButton.IsEnabled = false;
            testText.Text = "保存后会清除已存密钥。";
        };

        presetCombo.SelectionChanged += (_, _) =>
        {
            if (presetCombo.SelectedIndex < 0 || presetCombo.SelectedIndex >= Spec.Presets.Length) return;
            var preset = Spec.Presets[presetCombo.SelectedIndex];
            nameBox.Text = preset.Name;
            urlBox.Text = preset.BaseUrl;
            modelBox.Text = preset.Model;
            requiresKeyBox.IsChecked = preset.RequiresKey;
        };

        var content = new StackPanel { MinWidth = 420, Spacing = 0 };
        content.Children.Add(presetCombo);
        content.Children.Add(nameBox);
        content.Children.Add(urlBox);
        content.Children.Add(modelBox);
        content.Children.Add(keyBox);
        content.Children.Add(requiresKeyBox);
        content.Children.Add(testButton);
        content.Children.Add(clearKeyButton);
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
                RequiresKey = requiresKeyBox.IsChecked == true,
            }, activate: true);

            // 点了「清除已保存的密钥」且保存时字段仍为空：删除已存密钥。
            // 空 key 本身在 Upsert 里表示「保留」，所以清除要单独走这一步。
            if (clearKeyRequested && editing is not null && string.IsNullOrEmpty(keyBox.Password))
            {
                _providerStore.ClearKey(editing.Id);
            }

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

    private void OnAutoCheckToggled(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        _settingsStore.Update(settings => settings.AutoCheckUpdates = AutoCheckToggle.IsOn);
        SaveSettings();
    }

    /// <summary>
    /// 启动后静默查一次。没网、被限流、已是最新都不打扰用户；
    /// 只有确实有新版本时才在任务页顶部亮一条 InfoBar。
    /// </summary>
    private async Task CheckUpdatesQuietlyAsync()
    {
        if (!_settingsStore.Settings.AutoCheckUpdates) return;

        try
        {
            // 让窗口先画出来，别和启动动画抢时间。
            await Task.Delay(TimeSpan.FromSeconds(3));
            var checker = NewUpdateChecker();
            var info = await checker.CheckAsync();
            if (info is not null) ShowUpdateBar(info);
        }
        catch
        {
            // 后台检查失败保持静默。
        }
    }

    private void ShowUpdateBar(UpdateInfo info)
    {
        _updateInfo = info;
        UpdateBar.Title = $"发现新版本 {info.Version}";
        UpdateBar.Message = $"当前版本 {GetVersion()}，可以在下载页查看更新说明。";
        UpdateBar.IsOpen = true;
    }

    private async void OnUpdateView(object sender, RoutedEventArgs e)
    {
        if (_updateInfo is null) return;
        try
        {
            await Launcher.LaunchUriAsync(new Uri(_updateInfo.PageUrl));
        }
        catch (Exception error)
        {
            await ShowMessageAsync(error.Message);
        }
    }

    /// <summary>
    /// 安装版拿安装包（.exe）以便静默升级；便携版拿 zip，只能手动替换。
    /// </summary>
    private UpdateChecker NewUpdateChecker() => new()
    {
        CurrentVersion = GetVersion(),
        PreferredExtensions = UpdateInstaller.IsInstalled ? new[] { ".exe" } : new[] { ".zip" },
    };

    private async void OnCheckUpdates(object sender, RoutedEventArgs e)
    {
        SaveSettings();
        var checker = NewUpdateChecker();
        try
        {
            var info = await checker.CheckAsync();
            if (info is null)
            {
                await ShowMessageAsync("已是最新版本。");
                return;
            }

            var canSelfInstall = UpdateInstaller.CanSelfInstall(info);
            var content = new StackPanel { Spacing = 8 };
            if (canSelfInstall)
            {
                content.Children.Add(new TextBlock
                {
                    Text = "下载完成后会自动启动安装程序：AITrans 会关闭，装完自动重新打开；正在运行的任务会中断。",
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = UiBrush.Get("TextFillColorSecondaryBrush", Microsoft.UI.Colors.Gray),
                });
            }
            content.Children.Add(new ScrollViewer
            {
                MaxHeight = 280,
                Content = new TextBlock
                {
                    Text = string.IsNullOrWhiteSpace(info.Notes) ? "该版本没有填写更新说明。" : info.Notes,
                    TextWrapping = TextWrapping.Wrap,
                },
            });

            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"发现新版本 {info.Version}",
                Content = content,
                PrimaryButtonText = canSelfInstall ? "下载并安装" : "下载更新",
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
                    var downloadDir = _settingsStore.Settings.DownloadDir;
                    var path = await UpdateDownloader.DownloadAsync(
                        info, string.IsNullOrEmpty(downloadDir) ? null : downloadDir);
                    if (canSelfInstall)
                    {
                        UpdateInstaller.Run(path);
                        StatusLabel.Text = "正在安装更新，AITrans 会自动重启…";
                        return;
                    }

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
