// Minimal MAUI application for the opt-in Razor project: one page whose only control is a
// BlazorWebView whose root component is BlazorCounter.razor. The page exists to prove the
// Microsoft.NET.Sdk.Razor path and its payload shape, not to repeat the demo's control gallery
// (see test/hello-maui-app/App.cs for that).
using Microsoft.AspNetCore.Components.WebView.Maui;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using System.Diagnostics.CodeAnalysis;

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
    // NativeAOT root: the WebView renderer creates the root component through
    // ActivatorUtilities over RootComponent.ComponentType, and that property carries no
    // DynamicallyAccessedMembers annotation, so a trimmed publish removes the component's
    // constructor and the attach fails with "A suitable constructor ... could not be located"
    // (FIX-BWVMount). All: the component's [Inject] properties (their setters and the
    // attributes the DefaultComponentPropertyActivator reflects over) have no static user
    // either, so PublicConstructors alone left IJSRuntime null at run time.
    [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(BlazorCounter))]
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
