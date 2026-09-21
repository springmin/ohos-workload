// Minimal MAUI application for the opt-in Razor project: one page whose only control is a
// BlazorWebView whose root component is BlazorCounter.razor. The page exists to prove the
// Microsoft.NET.Sdk.Razor path and its payload shape, not to repeat the demo's control gallery
// (see test/hello-maui-app/App.cs for that).
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Maui;
using Microsoft.Maui.Controls;

namespace HelloMauiRazor;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new(new ContentPage
        {
            Title = "MAUI + Razor on OpenHarmony",
            Content = new VerticalStackLayout
            {
                Padding = 32,
                Spacing = 20,
                Children =
                {
                    new Label { Text = "MAUI + Razor on OpenHarmony", FontSize = 44 },
                    new Label { Text = "hello-maui-razor: BlazorCounter.razor through the platform slice", FontSize = 22 },
                    BuildBlazorWebView(),
                },
            },
        });

    // S1: the same wiring as the demo's App.cs. HostPage wwwroot/index.html is served from the
    // Blazor origin (https://0.0.0.0/) by the ArkTS shell: the handler registers the app content
    // root over the shell "blazor" command, the shell injects _framework/blazor.webview.js and
    // calls Blazor.start() on page end. The root component attaches to #app in that page and
    // renders BlazorCounter; its button click round-trips through the shell and the count
    // rendered inside the page advances.
    private static BlazorWebView BuildBlazorWebView()
    {
        var blazor = new BlazorWebView
        {
            HostPage = "wwwroot/index.html",
            HeightRequest = 600,
        };
        blazor.RootComponents.Add(new RootComponent
        {
            Selector = "#app",
            ComponentType = typeof(BlazorCounter),
        });
        return blazor;
    }
}
