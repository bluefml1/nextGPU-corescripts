using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class MoonlightPage : Page
{
    public MoonlightPage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        ControlPanel.Children.Clear();

        ActionPageTools.AddServiceButton(ControlPanel, "Restart Moonlight Web",
            () => App.Session.Services!.Restart("moonlight-web"),
            "Restart moonlight-web service");
        ActionPageTools.AddServiceButton(ControlPanel, "Restart Cloudflare Tunnel",
            () => App.Session.Services!.Restart("cloudflared"),
            "Restart cloudflared service");
        ControlPanel.Children.Add(ActionPageTools.MakeButton("Open Moonlight Web", "Open local Moonlight web UI", (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("http://127.0.0.1:8080") { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "NextGPU"); }
        }));

        ActionPageTools.AddOpenLogsButton(ControlPanel, "Open moonlight-web.log", "moonlight-web.log");
        ActionPageTools.AddOpenLogsButton(ControlPanel, "Open cloudflared log", "cloudflared.log");
    }
}
