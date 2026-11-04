// Ports Dictation/UI/SettingsKeysPage.swift and SettingsPlanUsage.swift: Settings → Keys & Plans (your
// own provider keys in shell.json, masked, each testable; the Claude Code / Codex plans with their CLI
// status; and each plan's usage).

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using OpenClicky.Core.Configuration;
using OpenClicky.Core.Providers;
using OpenClicky.Core.Settings;
using WpfUi = Wpf.Ui.Controls;

namespace OpenClicky.Windows.AppWindow;

internal sealed partial class SettingsRowFactory
{
    // MARK: - Keys & Plans

    /// <summary>What the keys list remembers between redraws: the provider being added, and what the last Test or Save said.</summary>
    private sealed class ProviderKeysState
    {
        public ProviderKey NewProvider = ProviderKey.OpenAI;
        public string? AddStatus;
        public readonly Dictionary<ProviderKey, string> RowStatus = [];
        public readonly HashSet<ProviderKey> Checking = [];
    }

    private readonly ProviderKeysState keysState = new();

    private UIElement? KeysRow(SettingsItem item, string query)
    {
        switch (item.Id)
        {
            case "keys.list":
                LiveContent? list = null;
                list = new LiveContent(() => ProviderKeysList(query, () => list?.Rebuild()), Changes.Shell, Changes.Of(Settings, nameof(Core.Dictation.DictationSettings.Region)));
                return list;
            case "keys.claudeCodePlan":
                return new PlanSubscriptionRow(AnswerSource.ClaudeCodePlan, item, query, services);
            case "keys.codexPlan":
                return new PlanSubscriptionRow(AnswerSource.CodexPlan, item, query, services);
            case "keys.usage.claudeCodePlan":
                return new PlanUsageRow(AnswerSource.ClaudeCodePlan, query);
            case "keys.usage.codexPlan":
                return new PlanUsageRow(AnswerSource.CodexPlan, query);
            case "keys.usage.sarvam":
                return Ui.Card(Ui.Row(item.Title, item.Detail, query, Ui.Button("Dashboard ↗", () => Ui.OpenExternal("https://dashboard.sarvam.ai"))));
            default:
                return null;
        }
    }

    /// <summary>
    /// Your keys: one row per saved key (Test, Remove) and an "Add a key" row whose menu holds the
    /// providers without one, so the list stays short however many providers there are.
    /// </summary>
    private StackPanel ProviderKeysList(string query, Action redraw)
    {
        var shell = OpenClickyConfiguration.Settings;
        var saved = ProviderKeys.Saved(shell);
        var unsaved = ProviderKeys.Unsaved(shell, Settings.Region);
        var stack = new StackPanel();
        foreach (var provider in saved)
        {
            var isChecking = keysState.Checking.Contains(provider);
            var detail = keysState.RowStatus.TryGetValue(provider, out var status) ? status : $"{provider.Detail()} {ProviderKeys.Masked(provider.SavedKey(shell)!)}";
            var testButton = Ui.Button(isChecking ? "Testing…" : "Test", () => TestKey(provider, redraw), isEnabled: !isChecking,
                toolTip: provider == ProviderKey.Spotify ? "Look one song up" : provider.SpeechVoiceId() is null ? "Ask it what colour a red square is" : "Have it say a word");
            var removeButton = Ui.Button("Remove", () =>
            {
                if (!SheetWindow.Confirm(actions.OwnerWindow, Settings, $"Remove the {provider.Title()} key?",
                        "It’s deleted from %USERPROFILE%\\.openclicky\\shell.json. Keep a copy if you’ll need it again.", "Remove")) return;
                SaveKey(provider, null);
                keysState.RowStatus.Remove(provider);
                keysState.AddStatus = $"{provider.Title()} key removed.";
                keysState.NewProvider = provider;
                redraw();
            });
            stack.Children.Add(Ui.Card(Ui.Row(provider.Title(), detail, query, Ui.HStack(8, testButton, removeButton))));
        }
        if (unsaved.Count == 0)
        {
            stack.Children.Add(Ui.Card(Ui.Row("Every provider has a key", keysState.AddStatus, query, null)));
            return stack;
        }
        if (!unsaved.Contains(keysState.NewProvider)) keysState.NewProvider = unsaved[0];
        var providerPicker = Ui.Picker(unsaved.Select(provider => (provider, provider.Title())), keysState.NewProvider, provider =>
        {
            keysState.NewProvider = provider;
            keysState.AddStatus = null;
            redraw();
        }, 170);
        var keyField = new WpfUi.PasswordBox { Width = 160, PlaceholderText = keysState.NewProvider.Placeholder(), VerticalAlignment = VerticalAlignment.Center };
        Ui.AutomationProperties(keyField, $"{keysState.NewProvider.Title()} key");
        var addButton = Ui.Button("Add", () => { }, WpfUi.ControlAppearance.Primary, isEnabled: false);
        void Add()
        {
            var trimmed = keyField.Password.Trim();
            if (trimmed.Length == 0) return;
            var provider = keysState.NewProvider;
            SaveKey(provider, trimmed);
            keysState.AddStatus = null;
            if (ProviderKeys.Unsaved(OpenClickyConfiguration.Settings, Settings.Region).FirstOrDefault() is var next) keysState.NewProvider = next;
            // Find out straight away whether it works.
            TestKey(provider, redraw);
        }
        keyField.PasswordChanged += (_, _) => addButton.IsEnabled = keyField.Password.Trim().Length > 0;
        keyField.KeyDown += (_, arguments) => { if (arguments.Key == System.Windows.Input.Key.Enter) Add(); };
        addButton.Click += (_, _) => Add();
        stack.Children.Add(Ui.Card(Ui.Row("Add a key", keysState.AddStatus ?? keysState.NewProvider.Detail(), query,
            Ui.HStack(8, providerPicker, keyField, addButton))));
        return stack;
    }

    private static void SaveKey(ProviderKey provider, string? key)
    {
        OpenClickyConfiguration.Update(shell => provider.Store(shell, key));
        // A changed key is a changed credential: a live realtime session reconnects with it.
        // (Wired: the Mac posted credentialsChangedNotification here; the settings-file
        // watcher raises OpenClickyConfiguration.CredentialsChanged once it sees the write, and CompanionManager reconnects.)
        ShellSettingsRevision.NoteChanged();
    }

    private void TestKey(ProviderKey provider, Action redraw)
    {
        if (provider.SavedKey(OpenClickyConfiguration.Settings) is null) return;
        keysState.Checking.Add(provider);
        keysState.RowStatus[provider] = "Checking…";
        redraw();
        _ = RunTestAsync();

        async Task RunTestAsync()
        {
            string sentence;
            try
            {
                if (provider.AnswerSource() is { } source) sentence = await services.Services.TestAnswerSourceAsync(source);
                // A voice key is checked by having it say one word.
                else if (provider.SpeechVoiceId() is { } voiceId) sentence = await services.Services.TestVoiceKeyAsync(voiceId);
                // Spotify credentials are checked by looking one song up.
                else if (provider == ProviderKey.Spotify) sentence = await Core.Actions.MusicLookup.TestCredentialsAsync(provider.SavedKey(OpenClickyConfiguration.Settings));
                else sentence = "Saved.";
            }
            catch (Exception error)
            {
                sentence = error.Message;
            }
            keysState.RowStatus[provider] = sentence;
            keysState.Checking.Remove(provider);
            redraw();
        }
    }

    /// <summary>A plan the person already pays for: whether its CLI is here and signed in, and the switch that lets it answer.</summary>
    private sealed class PlanSubscriptionRow : ContentControl
    {
        private readonly AnswerSource plan;
        private readonly SettingsItem item;
        private readonly string query;
        private readonly MainWindowServices services;
        private PlanCliStatus? status;
        private string? checkSentence;
        private bool isChecking;

        public PlanSubscriptionRow(AnswerSource plan, SettingsItem item, string query, MainWindowServices services)
        {
            this.plan = plan;
            this.item = item;
            this.query = query;
            this.services = services;
            HorizontalContentAlignment = HorizontalAlignment.Stretch;
            Render();
            Loaded += async (_, _) =>
            {
                try { status = await services.Services.PlanStatusAsync(plan); }
                catch (Exception error) { AppLog.Write($"plans: status failed: {error.Message}"); status = PlanCliStatus.NotInstalled; }
                Render();
            };
        }

        private void Render()
        {
            var isOn = PlanSubscription.IsOn(plan, OpenClickyConfiguration.Settings);
            var detail = checkSentence ?? PlanSubscription.Detail(plan, status, isOn);
            var controls = Ui.HStack(8,
                status == PlanCliStatus.Ready ? Ui.Button(isChecking ? "Testing…" : "Test", Test, isEnabled: !isChecking, toolTip: "Ask it what colour a red square is") : null,
                status == PlanCliStatus.NotInstalled ? Ui.Button("Get It ↗", () => Ui.OpenExternal(PlanSubscription.GetItUrl(plan))) : null,
                Ui.Toggle(isOn, newValue =>
                {
                    OpenClickyConfiguration.Update(shell =>
                    {
                        if (plan == AnswerSource.ClaudeCodePlan) shell.UseClaudeCodePlan = newValue;
                        else shell.UseCodexPlan = newValue;
                    });
                    ShellSettingsRevision.NoteChanged();
                    Render();
                }, isEnabled: status == PlanCliStatus.Ready || isOn));
            Content = Ui.Card(Ui.Row(item.Title, detail, query, controls));
        }

        private async void Test()
        {
            isChecking = true;
            checkSentence = "Checking… a plan takes a few seconds.";
            Render();
            try { checkSentence = await services.Services.TestAnswerSourceAsync(plan); }
            catch (Exception error) { checkSentence = error.Message; }
            isChecking = false;
            Render();
        }
    }

    /// <summary>
    /// A plan's usage: the first lines are what OpenClicky sent; the bars are the plan's own limits,
    /// which count everything on that account.
    /// </summary>
    private sealed class PlanUsageRow : ContentControl
    {
        private readonly AnswerSource plan;
        private readonly string query;

        public PlanUsageRow(AnswerSource plan, string query)
        {
            this.plan = plan;
            this.query = query;
            HorizontalContentAlignment = HorizontalAlignment.Stretch;
            Render();
            Loaded += async (_, _) =>
            {
                PlanUsageLedger.Changed += OnChanged;
                PlanLimitStore.Shared.Changed += OnChanged;
                Render();
                if (plan == AnswerSource.CodexPlan) await PlanLimitStore.Shared.RefreshCodexAsync(force: true);
            };
            Unloaded += (_, _) =>
            {
                PlanUsageLedger.Changed -= OnChanged;
                PlanLimitStore.Shared.Changed -= OnChanged;
            };
        }

        private void OnChanged() => Dispatcher.BeginInvoke(Render);

        private void Render()
        {
            var now = DateTimeOffset.Now;
            var startOfDay = new DateTimeOffset(now.Date, now.Offset);
            var startOfMonth = new DateTimeOffset(new DateTime(now.Year, now.Month, 1), now.Offset);
            var snapshot = PlanLimitStore.Shared.Snapshot(plan);
            var detail = PlanRows.UsageDetail(
                PlanUsageLedger.Shared.Totals(plan, startOfDay), PlanUsageLedger.Shared.Totals(plan, startOfMonth),
                snapshot, PlanAvailability.Shared.ExhaustedUntil(plan));
            var bars = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
            foreach (var window in snapshot?.Windows ?? [])
            {
                bars.Children.Add(Ui.Text($"{window.Title}: {(int)Math.Round(window.UsedFraction * 100, MidpointRounding.AwayFromZero)}% used", SettingsLook.CaptionSize, SettingsLook.TextSecondary, wrap: false));
                bars.Children.Add(new ProgressBar { Maximum = 1, Value = window.UsedFraction, Width = 130, Height = 4, Margin = new Thickness(0, 3, 0, 3) });
                if (PlanRows.ResetText(window.ResetsAt) is { } reset) bars.Children.Add(Ui.Text(reset, SettingsLook.CaptionSize, SettingsLook.TextSecondary, wrap: false));
            }
            Content = Ui.Card(Ui.Row($"{plan.ShortName()} usage", detail, query, bars));
        }
    }
}
