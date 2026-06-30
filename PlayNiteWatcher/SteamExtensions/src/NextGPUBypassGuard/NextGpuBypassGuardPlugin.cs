using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using Newtonsoft.Json;
using Playnite.SDK;
using Playnite.SDK.Events;
using Playnite.SDK.Models;
using Playnite.SDK.Plugins;

namespace NextGPUBypassGuard
{
    public class BypassBindingsDocument
    {
        [JsonProperty("bypassesPath")]
        public string BypassesPath { get; set; } = "";

        [JsonProperty("bindings")]
        public List<BypassBindingEntry> Bindings { get; set; } = new List<BypassBindingEntry>();
    }

    public class BypassBindingEntry
    {
        [JsonProperty("playniteId")]
        public string PlayniteId { get; set; } = "";

        [JsonProperty("title")]
        public string Title { get; set; } = "";

        [JsonProperty("launchPath")]
        public string LaunchPath { get; set; } = "";

        [JsonProperty("syncType")]
        public string SyncType { get; set; } = "";
    }

    public class NextGpuBypassGuardPlugin : GenericPlugin
    {
        private static readonly ILogger Logger = LogManager.GetLogger();
        private readonly Timer reconcileTimer;
        private readonly object reconcileLock = new object();
        private int reconcilePending;

        public static readonly Guid PluginGuid = new Guid("7E4F8A2B-3C1D-4E9F-B8A6-1D2E3F4A5B6C");

        public override Guid Id => PluginGuid;

        public NextGpuBypassGuardPlugin(IPlayniteAPI api) : base(api)
        {
            reconcileTimer = new Timer(_ => RunReconcile("debounced"), null, Timeout.Infinite, Timeout.Infinite);
            Properties = new GenericPluginProperties
            {
                HasSettings = false
            };
        }

        public override void OnApplicationStarted(OnApplicationStartedEventArgs args)
        {
            PlayniteApi.Database.Games.ItemUpdated += OnGameItemUpdated;
            RunReconcile("startup");
        }

        private void OnGameItemUpdated(object sender, ItemUpdatedEventArgs<Game> e)
        {
            ScheduleReconcile();
        }

        private void ScheduleReconcile()
        {
            Interlocked.Exchange(ref reconcilePending, 1);
            reconcileTimer.Change(3000, Timeout.Infinite);
        }

        private void RunReconcile(string reason)
        {
            if (Interlocked.Exchange(ref reconcilePending, 0) == 0 && reason == "debounced")
            {
                return;
            }

            lock (reconcileLock)
            {
                try
                {
                    var doc = LoadBindingsDocument();
                    if (doc?.Bindings == null || doc.Bindings.Count == 0)
                    {
                        return;
                    }

                    var restored = 0;
                    foreach (var binding in doc.Bindings)
                    {
                        if (TryRestoreBinding(binding))
                        {
                            restored++;
                        }
                    }

                    if (restored > 0)
                    {
                        Logger.Info($"NextGPUBypassGuard: restored {restored} bypass play path(s) ({reason})");
                    }
                }
                catch (Exception ex)
                {
                    Logger.Error(ex, "NextGPUBypassGuard reconcile failed");
                }
            }
        }

        private BypassBindingsDocument LoadBindingsDocument()
        {
            var path = GetBindingsFilePath();
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                return null;
            }

            var json = File.ReadAllText(path);
            return JsonConvert.DeserializeObject<BypassBindingsDocument>(json);
        }

        private string GetBindingsFilePath()
        {
            var extensionsData = PlayniteApi.Paths.ExtensionsDataPath;
            if (string.IsNullOrWhiteSpace(extensionsData))
            {
                return null;
            }

            return Path.Combine(extensionsData, "NextGPU", "bypass-bindings.json");
        }

        private bool TryRestoreBinding(BypassBindingEntry binding)
        {
            if (binding == null || string.IsNullOrWhiteSpace(binding.LaunchPath))
            {
                return false;
            }

            if (!File.Exists(binding.LaunchPath))
            {
                Logger.Warn($"NextGPUBypassGuard: shortcut missing for '{binding.Title}': {binding.LaunchPath}");
                return false;
            }

            var game = ResolveGame(binding);
            if (game == null)
            {
                Logger.Warn($"NextGPUBypassGuard: no Playnite game for binding '{binding.Title}'");
                return false;
            }

            var launchPath = Path.GetFullPath(binding.LaunchPath);
            var workingDir = Path.GetDirectoryName(launchPath) ?? "";
            var currentPath = game.GameActions?
                .FirstOrDefault(a => a.IsPlayAction && !string.IsNullOrWhiteSpace(a.Path))?.Path ?? "";

            if (string.Equals(currentPath, launchPath, StringComparison.OrdinalIgnoreCase)
                && game.IncludeLibraryPluginAction == false
                && string.Equals(game.InstallDirectory ?? "", workingDir, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            game.IncludeLibraryPluginAction = false;
            game.InstallDirectory = workingDir;
            game.IsInstalled = true;
            game.GameActions = new ObservableCollection<GameAction>
            {
                new GameAction
                {
                    Name = "Play",
                    Type = GameActionType.File,
                    Path = launchPath,
                    WorkingDir = workingDir,
                    IsPlayAction = true,
                    TrackingMode = TrackingMode.Default
                }
            };

            PlayniteApi.Database.Games.Update(game);
            Logger.Info($"NextGPUBypassGuard: restored {game.Name} -> {launchPath}");
            return true;
        }

        private Game ResolveGame(BypassBindingEntry binding)
        {
            if (!string.IsNullOrWhiteSpace(binding.PlayniteId) && Guid.TryParse(binding.PlayniteId, out var id))
            {
                var byId = PlayniteApi.Database.Games.Get(id);
                if (byId != null)
                {
                    return byId;
                }
            }

            if (string.IsNullOrWhiteSpace(binding.Title))
            {
                return null;
            }

            var titleKey = binding.Title.Trim();
            return PlayniteApi.Database.Games
                .Where(g => g != null && string.Equals(g.Name?.Trim(), titleKey, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(g => g.PluginId == Guid.Parse("CB91DFC9-B977-43BF-8E70-55F46E410FAB"))
                .ThenByDescending(g => g.PluginId == Guid.Parse("00000002-DBD1-46C6-B5D0-B1BA559D10E4"))
                .FirstOrDefault();
        }
    }
}
