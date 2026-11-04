using System.Diagnostics;
using AITrans.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace AITrans.App;

public sealed partial class MainWindow : Window
{
    private readonly SettingsStore _settingsStore = new();
    private readonly ProviderStore _providerStore;
    private readonly List<string> _files = [];
    private readonly Dictionary<string, FileResult> _results = new();

    private CancellationTokenSource? _cts;
    private bool _running;
    private bool _initializing = true;

    public MainWindow()
    {
        InitializeComponent();

        _providerStore = new ProviderStore(new DpapiSecretStore(AppPaths.SecretsFile));

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

        BuildCombos();
        ApplySettingsToUi();
        RefreshProviders();
        RefreshFiles();

        VersionText.Text = $"版本 {GetVersion()}";
        Closed += (_, _) => SaveSettings();
        _initializing = false;
    }

    // ---------------------------------------------------------------- 初始化

    private static string GetVersion()
    {
        var version = typeof(MainWindow).Assembly.GetName().Version;
        return version is null ? "0.0.0" : $"{version.Major}.{version.Minor}.{version.Build}";
    }

    private void BuildCombos()
    {
        EngineCombo.Items.Add("API 提供商");
        EngineCombo.Items.Add("本地 Ollama");
        LanguageCombo.Items.Add("中文");
        LanguageCombo.Items.Add("英文");
        LanguageCombo.Items.Add("日文");
        LanguageCombo.Items.Add("韩文");
        OutputCombo.Items.Add("源文件目录");
        OutputCombo.Items.Add("应用输出目录");
        OutputCombo.Items.Add("自定义目录");
    }

    private void ApplySettingsToUi()
    {
        var settings = _settingsStore.Settings;
        EngineCombo.SelectedIndex = settings.Backend == Engine.api ? 0 : 1;
        ModelBox.Text = settings.ApiModel;
        LanguageCombo.SelectedIndex = (int)settings.Lang;
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
        WorkersBox.Value = settings.ApiWorkers;
        RetriesBox.Value = settings.ApiRetries;
        CustomDirPanel.Visibility = settings.OutputMode == OutputMode.custom ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SaveSettings()
    {
        var settings = _settingsStore.Settings;
        settings.Backend = EngineCombo.SelectedIndex == 1 ? Engine.ollama : Engine.api;
        settings.ApiModel = ModelBox.Text.Trim();
        settings.Lang = (Language)Math.Max(0, LanguageCombo.SelectedIndex);
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
        settings.ApiWorkers = double.IsNaN(WorkersBox.Value) ? 20 : (int)WorkersBox.Value;
        settings.ApiRetries = double.IsNaN(RetriesBox.Value) ? 2 : (int)RetriesBox.Value;

        try
        {
            _settingsStore.Save(AppPaths.SettingsFile);
        }
        catch (Exception)
        {
            // 保存失败不阻塞关闭。
        }
    }

    private void RefreshProviders()
    {
        ProviderCombo.Items.Clear();
        foreach (var provider in _providerStore.Providers)
        {
            ProviderCombo.Items.Add(provider.Name);
        }
        var activeIndex = _providerStore.Providers.FindIndex(p => p.Id == _providerStore.ActiveId);
        ProviderCombo.SelectedIndex = activeIndex >= 0 ? activeIndex : (_providerStore.Providers.Count > 0 ? 0 : -1);
    }

    // ---------------------------------------------------------------- 文件

    private void AddFile(string path)
    {
        if (!string.Equals(Path.GetExtension(path), ".srt", StringComparison.OrdinalIgnoreCase)) return;
        var full = Path.GetFullPath(path);
        if (_files.Any(existing => string.Equals(existing, full, StringComparison.OrdinalIgnoreCase))) return;
        _files.Add(full);
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
        FileList.Items.Clear();
        EmptyState.Visibility = _files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        foreach (var path in _files)
        {
            var name = Path.GetFileName(path);
            _results.TryGetValue(name, out var result);

            var row = new Grid { Padding = new Thickness(4, 6, 4, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var icon = new FontIcon
            {
                Glyph = GlyphFor(result),
                FontSize = 16,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 10, 0),
            };
            Grid.SetColumn(icon, 0);

            var texts = new StackPanel { Spacing = 2 };
            texts.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
            texts.Children.Add(new TextBlock
            {
                Text = SubtitleFor(path, result),
                FontSize = 12,
                Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            Grid.SetColumn(texts, 1);

            row.Children.Add(icon);
            row.Children.Add(texts);
            FileList.Items.Add(row);
        }

        if (_files.Count > 0)
        {
            StatusText.Text = $"已添加 {_files.Count} 个文件";
        }
    }

    private static string GlyphFor(FileResult? result) => result?.Status switch
    {
        FileResult.StatusKind.success => "\uE73E",
        FileResult.StatusKind.skipped => "\uE8AB",
        FileResult.StatusKind.failed => "\uE7BA",
        _ => "\uE8A5",
    };

    private static string SubtitleFor(string path, FileResult? result)
    {
        if (result is null) return Path.GetDirectoryName(path) ?? "";
        return result.Status switch
        {
            FileResult.StatusKind.success =>
                $"成功 {result.TranslatedCount} 段{(result.ErrorCount > 0 ? $"，失败 {result.ErrorCount} 段" : "")}",
            FileResult.StatusKind.skipped => "已存在，跳过",
            _ => result.Error ?? "失败",
        };
    }

    private static Brush ThemeBrush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(Colors.Gray);

    // ---------------------------------------------------------------- 交互

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

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        var index = ProviderCombo.SelectedIndex;
        if (index < 0 || index >= _providerStore.Providers.Count) return;
        try
        {
            _providerStore.SetActive(_providerStore.Providers[index].Id);
            _providerStore.Save(AppPaths.ProvidersFile);
        }
        catch (Exception error)
        {
            _ = ShowMessageAsync(error.Message);
        }
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
            await ShowMessageAsync("请先在「管理提供商」里添加并启用一个提供商。");
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
        _results.Clear();
        RefreshFiles();
        StartButtonText.Text = "取消";
        JobProgressBar.IsIndeterminate = false;
        JobProgressBar.Value = 0;
        StatusText.Text = "准备开始…";

        var progress = new Progress<JobProgress>(update =>
        {
            JobProgressBar.Value = update.Total == 0 ? 0 : update.Completed * 100.0 / update.Total;
            StatusText.Text = string.IsNullOrEmpty(update.CurrentName)
                ? "完成"
                : $"正在处理 {update.CurrentName}";
        });

        try
        {
            if (usesOllama)
            {
                StatusText.Text = "正在检查本地 Ollama…";
                await OllamaService.EnsureRunningAsync();
                await OllamaService.EnsureModelAsync(settings.OllamaModel);
            }

            var results = await runner.RunAsync(
                _files,
                settings,
                AppPaths.DefaultOutputDirectory,
                customDirectory,
                progress,
                cancellationToken: _cts.Token);

            foreach (var result in results) _results[result.Name] = result;
            RefreshFiles();

            var ok = results.Count(result => result.Status == FileResult.StatusKind.success);
            var skipped = results.Count(result => result.Status == FileResult.StatusKind.skipped);
            var failed = results.Count(result => result.Status == FileResult.StatusKind.failed);
            JobProgressBar.Value = 100;
            StatusText.Text = $"完成：成功 {ok}，跳过 {skipped}，失败 {failed}";
            if (failed > 0) await ShowMessageAsync($"有 {failed} 个文件失败，详情见列表。");
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "已取消";
        }
        catch (Exception error)
        {
            StatusText.Text = "已停止";
            await ShowMessageAsync(error.Message);
        }
        finally
        {
            _running = false;
            StartButtonText.Text = "开始";
            JobProgressBar.IsIndeterminate = false;
            _cts?.Dispose();
            _cts = null;
        }
    }

    // ---------------------------------------------------------------- 提供商

    private async void OnManageProviders(object sender, RoutedEventArgs e)
    {
        var combo = new ComboBox { MinWidth = 320, Header = "提供商" };
        foreach (var provider in _providerStore.Providers) combo.Items.Add(provider.Name);

        var nameBox = new TextBox { Header = "名称", MinWidth = 320 };
        var urlBox = new TextBox { Header = "接口地址", MinWidth = 320 };
        var modelBox = new TextBox { Header = "模型", MinWidth = 320 };
        var keyBox = new PasswordBox { Header = "API Key", MinWidth = 320 };
        var testText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
        };

        var presetCombo = new ComboBox { MinWidth = 200, Header = "从预设新建" };
        foreach (var preset in Spec.Presets) presetCombo.Items.Add(preset.Name);

        string? editingId = _providerStore.ActiveId ?? _providerStore.Providers.FirstOrDefault()?.Id;

        void LoadProvider(string? id)
        {
            editingId = id;
            var provider = id is null ? null : _providerStore.Find(id);
            combo.SelectedIndex = provider is null ? -1 : _providerStore.Providers.FindIndex(p => p.Id == provider.Id);
            nameBox.Text = provider?.Name ?? "";
            urlBox.Text = provider?.BaseUrl ?? "";
            modelBox.Text = provider?.Model ?? "";
            keyBox.Password = provider?.ApiKey ?? "";
            testText.Text = "";
        }

        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedIndex >= 0 && combo.SelectedIndex < _providerStore.Providers.Count)
            {
                LoadProvider(_providerStore.Providers[combo.SelectedIndex].Id);
            }
        };

        presetCombo.SelectionChanged += (_, _) =>
        {
            if (presetCombo.SelectedIndex < 0 || presetCombo.SelectedIndex >= Spec.Presets.Length) return;
            var preset = Spec.Presets[presetCombo.SelectedIndex];
            editingId = null;
            combo.SelectedIndex = -1;
            nameBox.Text = preset.Name;
            urlBox.Text = preset.BaseUrl;
            modelBox.Text = preset.Model;
            keyBox.Password = "";
        };

        var newButton = new Button { Content = "新建" };
        newButton.Click += (_, _) => LoadProvider(null);

        var testButton = new Button { Content = "测试连接" };
        testButton.Click += async (_, _) =>
        {
            testText.Text = "正在测试…";
            testText.Text = await TestProviderAsync(urlBox.Text.Trim(), keyBox.Password);
        };

        var importButton = new Button { Content = "从旧版导入…" };
        importButton.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker();
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add(".json");
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            try
            {
                var count = _providerStore.ImportLegacy(file.Path, null);
                _providerStore.Save(AppPaths.ProvidersFile);
                combo.Items.Clear();
                foreach (var provider in _providerStore.Providers) combo.Items.Add(provider.Name);
                RefreshProviders();
                testText.Text = count > 0 ? $"已导入 {count} 个提供商。" : "没有找到可导入的配置。";
            }
            catch (Exception error)
            {
                testText.Text = error.Message;
            }
        };

        var content = new StackPanel { Spacing = 10, MinWidth = 380 };
        content.Children.Add(combo);
        content.Children.Add(newButton);
        content.Children.Add(presetCombo);
        content.Children.Add(nameBox);
        content.Children.Add(urlBox);
        content.Children.Add(modelBox);
        content.Children.Add(keyBox);
        content.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { testButton, importButton },
        });
        content.Children.Add(testText);

        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "提供商",
            Content = content,
            PrimaryButtonText = "保存",
            SecondaryButtonText = "删除",
            CloseButtonText = "关闭",
            DefaultButton = ContentDialogButton.Primary,
        };

        LoadProvider(editingId);
        var result = await dialog.ShowAsync();

        if (result == ContentDialogResult.Primary)
        {
            try
            {
                _providerStore.Upsert(new Provider
                {
                    Id = editingId ?? "",
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
        else if (result == ContentDialogResult.Secondary && editingId is not null)
        {
            _providerStore.Delete(editingId);
            _providerStore.Save(AppPaths.ProvidersFile);
            RefreshProviders();
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
                XamlRoot = Content.XamlRoot,
                Title = $"发现新版本 {info.Version}",
                Content = new ScrollViewer
                {
                    MaxHeight = 320,
                    Content = new TextBlock { Text = info.Notes, TextWrapping = TextWrapping.Wrap },
                },
                PrimaryButtonText = "打开下载页",
                CloseButtonText = "稍后",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
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

    private async Task ShowMessageAsync(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "提示",
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "好",
        };
        await dialog.ShowAsync();
    }
}
