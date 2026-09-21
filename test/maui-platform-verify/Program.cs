using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;

// A small image file for the Image handler.
string imagePath = Path.Combine(Path.GetTempPath(), "verify-image.png");
File.WriteAllBytes(imagePath, Convert.FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));

gestures.Drawable = new ProbeDrawable();
OpenHarmonyWindowRenderer.SurfaceBegin = (_, _) => true;
OpenHarmonyWindowRenderer.SurfacePresent = () => { };
var builder = MauiApp.CreateBuilder();
builder.UseOpenHarmony();
builder.UseMauiApp<TestApp>();
var app = builder.Build();
var host = app.Services.GetRequiredService<OpenHarmonyMauiAppHost>();
host.Run(app.Services.GetRequiredService<IApplication>());

var navRoot = (NavigationPage)host.Window!.Content;
var page = (ContentPage)navRoot.CurrentPage;
var root = (VerticalStackLayout)page.Content!;
Console.WriteLine($"[verify] nav state: stack={navRoot.Navigation.NavigationStack.Count} current={(navRoot.CurrentPage?.GetType().Name ?? "null")} currentHandler={navRoot.CurrentPage?.Handler?.GetType().Name ?? "null"} layoutHandler={root.Handler?.GetType().Name ?? "null"} pageFrame={page.Frame}");


// Window handler + lifecycle (no platform window required now).
var window = host.Window;
Console.WriteLine($"[verify] window handler={window.Handler?.GetType().Name ?? "null"}");
try
{
    window.Handler?.Invoke("Created");
    Console.WriteLine("[verify] window Created() ok");
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] window Created() threw {ex.GetType().Name}: {ex.Message}");
}

host.Arrange(1080, 1920);
Console.WriteLine($"[verify] after arrange: root={root.Frame} page={page.Frame} nav={navRoot.Frame}");
Console.WriteLine(host.Describe().Split('\n').Skip(1).FirstOrDefault());

// Tap the entry -> focus; drag the scroll view -> offset changes.
var entry = root.Children.OfType<Entry>().FirstOrDefault();
if (entry is not null)
{
    Rect entryFrame = entry.Frame;
    bool d = host.HandleTouch(true, false, (float)(entryFrame.X + 10), (float)(entryFrame.Y + 10));
    bool u = host.HandleTouch(false, true, (float)(entryFrame.X + 10), (float)(entryFrame.Y + 10));
    var entryPlatform = (OpenHarmonyView)entry.Handler!.PlatformView!;
    Console.WriteLine($"[verify] entry tap handled(down={d}, up={u}) platformFocused={entryPlatform.IsFocused} virtualFocused={entry.IsFocused}");
}

var scroll = root.Children.OfType<ScrollView>().FirstOrDefault();
if (scroll is not null)
{
    Rect scrollFrame = scroll.Frame;
    float sx = (float)(scrollFrame.X + scrollFrame.Width / 2);
    bool sd = host.HandleTouch(true, false, sx, (float)(scrollFrame.Y + 40));
    bool m1 = host.HandleMove(sx, (float)(scrollFrame.Y + 10));
    bool m2 = host.HandleMove(sx, (float)(scrollFrame.Y - 30));
    bool su = host.HandleTouch(false, true, sx, (float)(scrollFrame.Y - 30));
    Console.WriteLine($"[verify] scroll drag handled(down={sd}, move1={m1}, move2={m2}, up={su})");
    Console.WriteLine($"[verify] scroll offsetY={((IScrollView)scroll).VerticalOffset:0} (virtual view)");
    Console.WriteLine($"[verify] after drag: {host.Describe().Split('\n').FirstOrDefault(l => l.Contains("scroll="))?.Trim()}");
}


// W22-7: animation (MAUI ticker), picker dropdown, tabbed page.
var fadeCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "fade me");
if (fadeCtl is not null)
{
    var fadeTask = fadeCtl.FadeTo(0.25, 120, Easing.Linear);
    if (await Task.WhenAny(fadeTask, Task.Delay(3000)) != fadeTask)
    {
        Console.WriteLine($"[verify] FadeTo did not finish (opacity={fadeCtl.Opacity:0.##})");
    }
    else
    {
        Console.WriteLine($"[verify] FadeTo completed opacity={fadeCtl.Opacity:0.##}");
    }
    await fadeCtl.FadeTo(1.0, 60, Easing.Linear);
}

var pickerTest = root.Children.OfType<Picker>().FirstOrDefault();
if (pickerTest is not null && pickerTest.Handler?.PlatformView is OpenHarmonyView pickerPlatform)
{
    Rect f = pickerTest.Frame;
    host.HandleTouch(true, false, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] picker popup visible={pickerPlatform.PopupVisible} items={pickerPlatform.PopupItems.Count}");
    float popupItemY = (float)(f.Y + f.Height + OpenHarmonyView.PopupRowHeight * 2 + OpenHarmonyView.PopupRowHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + 20), popupItemY);
    host.HandleTouch(false, true, (float)(f.X + 20), popupItemY);
    Console.WriteLine($"[verify] picker selected index={pickerTest.SelectedIndex} text='{pickerPlatform.Text}' popup={pickerPlatform.PopupVisible}");
}

// W22-9: async image source resolves into the platform view.
await Task.Delay(200);
var streamCtl = root.Children.OfType<Image>().FirstOrDefault(i => i.Source is StreamImageSource);
if (streamCtl?.Handler?.PlatformView is OpenHarmonyView streamPlatform)
{
    Console.WriteLine($"[verify] stream image bytes={streamPlatform.ImageBytes?.Length ?? 0}");
}

// W22-8: date/time picker dropdowns.
var dateCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<DatePicker>().FirstOrDefault();
if (dateCtl is not null && dateCtl.Handler?.PlatformView is OpenHarmonyView datePlatform)
{
    Rect f = dateCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] datepicker open={datePlatform.PopupVisible} month={datePlatform.CalendarYear}-{datePlatform.CalendarMonth:00} selected={datePlatform.CalendarSelectedDay}");
    // Tap "next month" (>), then a day in the shown month.
    float headerY = (float)(f.Y + f.Height + OpenHarmonyView.CalendarHeaderHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + OpenHarmonyView.CalendarWidth - 20), headerY);
    host.HandleTouch(false, true, (float)(f.X + OpenHarmonyView.CalendarWidth - 20), headerY);
    int day = 15;
    int leading = ((int)new DateTime(datePlatform.CalendarYear, datePlatform.CalendarMonth, 1).DayOfWeek + 6) % 7;
    int cell = leading + day - 1;
    float cellX = (float)(f.X + (cell % 7) * (OpenHarmonyView.CalendarWidth / 7f) + OpenHarmonyView.CalendarWidth / 14f);
    float cellY = (float)(f.Y + f.Height + OpenHarmonyView.CalendarHeaderHeight + ((cell / 7) + 1) * OpenHarmonyView.CalendarRowHeight + OpenHarmonyView.CalendarRowHeight / 2);
    host.HandleTouch(true, false, cellX, cellY);
    host.HandleTouch(false, true, cellX, cellY);
    Console.WriteLine($"[verify] datepicker after calendar tap date={dateCtl.Date:yyyy-MM-dd} text='{datePlatform.Text}' popup={datePlatform.PopupVisible}");
}

var timeCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<TimePicker>().FirstOrDefault();
if (timeCtl is not null && timeCtl.Handler?.PlatformView is OpenHarmonyView timePlatform)
{
    Rect f = timeCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    float rowY = (float)(f.Y + f.Height + OpenHarmonyView.PopupRowHeight * 30 + OpenHarmonyView.PopupRowHeight / 2);
    host.HandleTouch(true, false, (float)(f.X + 10), rowY);
    host.HandleTouch(false, true, (float)(f.X + 10), rowY);
    Console.WriteLine($"[verify] timepicker time={timeCtl.Time:hh\\:mm} text='{timePlatform.Text}' popup={timePlatform.PopupVisible}");
}

// W22-22: Shell.GoToAsync route navigation.
Microsoft.Maui.Controls.Routing.RegisterRoute("verifyDetail", typeof(RoutedPage));
var shellForRoute = new Shell();
shellForRoute.Items.Add(new ShellContent { Title = "Home", ContentTemplate = new DataTemplate(() => new ContentPage { Title = "Home", Content = new Label { Text = "home" } }) });
OpenHarmonyHandlerConnector.ConnectTree(shellForRoute);
shellForRoute.Measure(1080, 1920);
shellForRoute.Arrange(new Rect(0, 0, 1080, 1920));
try
{
    await shellForRoute.GoToAsync("verifyDetail");
    await Task.Delay(150);
    var routePlatform = (OpenHarmonyView)shellForRoute.Handler!.PlatformView!;
    routePlatform.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell route current='{shellForRoute.CurrentPage?.Title}' chrome='{routePlatform.TitleText}' back={routePlatform.ShowsBack}");
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] shell route threw {ex.GetType().Name}: {ex.Message}");
}

// W22-10: Shell.
var rendererForShell = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var shellOne = new ContentPage { Title = "First", Content = new Label { Text = "shell one" } };
var shellTwo = new ContentPage { Title = "Second", Content = new Label { Text = "shell two" } };
var shell = new Shell();
shell.Items.Add(new ShellContent { Title = "First", ContentTemplate = new DataTemplate(() => shellOne) });
shell.Items.Add(new ShellContent { Title = "Second", ContentTemplate = new DataTemplate(() => shellTwo) });
OpenHarmonyHandlerConnector.ConnectTree(shell);
shell.Measure(1080, 1920);
shell.Arrange(new Rect(0, 0, 1080, 1920));
if (shell.Handler?.PlatformView is OpenHarmonyView shellPlatform)
{
    Console.WriteLine($"[verify] shell titles=[{string.Join(",", shellPlatform.TabTitles)}] selected={shellPlatform.SelectedTab} current='{shell.CurrentPage?.Title}'");
    double sy = shell.Frame.Height - OpenHarmonyView.TabBarHeight / 2;
    rendererForShell.HandleTouch(shell, true, false, (float)(shell.Frame.Width * 0.75), (float)sy);
    rendererForShell.HandleTouch(shell, false, true, (float)(shell.Frame.Width * 0.75), (float)sy);
    Console.WriteLine($"[verify] shell after tab tap selected={shellPlatform.SelectedTab} current='{shell.CurrentPage?.Title}' label={((shell.CurrentPage as ContentPage)?.Content as Label)?.Frame}");
    Console.WriteLine($"[verify] shell chrome title='{shellPlatform.TitleText}' back={shellPlatform.ShowsBack} hamburger={shellPlatform.ShowsHamburger}");
    var shellSection = shell.CurrentItem!.CurrentItem!;
    await shellSection.Navigation.PushAsync(new ContentPage { Title = "Pushed", Content = new Label { Text = "pushed page" } }, false);
    await Task.Delay(150);
    Console.WriteLine($"[verify] shell after push back={((OpenHarmonyView)shell.Handler!.PlatformView!).ShowsBack} title='{((OpenHarmonyView)shell.Handler!.PlatformView!).TitleText}'");
    var shellPlatform2 = (OpenHarmonyView)shell.Handler!.PlatformView!;
    shellPlatform2.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell after push back={shellPlatform2.ShowsBack} title='{shellPlatform2.TitleText}' backButtonHit={shellPlatform2.InBackButton(20, 20)}");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    await Task.Delay(250);
    shellPlatform2.ChromeRefresh?.Invoke();
    Console.WriteLine($"[verify] shell after back tap back={shellPlatform2.ShowsBack} title='{shellPlatform2.TitleText}' stack={shellSection.Navigation.NavigationStack.Count}");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    Console.WriteLine($"[verify] shell after hamburger open={shellPlatform.FlyoutOpen}");
    rendererForShell.HandleTouch(shell, true, false, 60, 90);
    rendererForShell.HandleTouch(shell, false, true, 60, 90);
    Console.WriteLine($"[verify] shell after flyout item tap open={shellPlatform.FlyoutOpen} current='{shell.CurrentPage?.Title}'");
    rendererForShell.HandleTouch(shell, true, false, 20, 20);
    rendererForShell.HandleTouch(shell, false, true, 20, 20);
    rendererForShell.HandleTouch(shell, true, false, 900, 600);
    rendererForShell.HandleTouch(shell, false, true, 900, 600);
    Console.WriteLine($"[verify] shell after outside tap open={shellPlatform.FlyoutOpen}");
}

// W22-13: Essentials (Preferences + FileSystem).
Preferences.Set("verify.int", 42);
Preferences.Set("verify.text", "hello");
Preferences.Set("verify.flag", true);
Console.WriteLine($"[verify] preferences int={Preferences.Get("verify.int", 0)} text='{Preferences.Get("verify.text", "")}' flag={Preferences.Get("verify.flag", false)} contains={Preferences.ContainsKey("verify.text")}");
var preferencesInstance = app.Services.GetRequiredService<Microsoft.Maui.Storage.IPreferences>();
var reloaded = new OpenHarmonyPreferences(((OpenHarmonyPreferences)preferencesInstance).FilePath);
Console.WriteLine($"[verify] preferences reloaded int={reloaded.Get("verify.int", 0)} (persisted)");
Preferences.Remove("verify.int");
Console.WriteLine($"[verify] preferences after remove contains={Preferences.ContainsKey("verify.int")}");
string probeFile = Path.Combine(FileSystem.AppDataDirectory, "verify.txt");
File.WriteAllText(probeFile, "essentials");
Console.WriteLine($"[verify] filesystem dir='{FileSystem.AppDataDirectory}' cache='{FileSystem.CacheDirectory}' read='{File.ReadAllText(probeFile)}'");

// W22-13b: grid collection view.
var gridCtl = root.Children.OfType<CollectionView>().FirstOrDefault(c => c.ItemsLayout is GridItemsLayout);
if (gridCtl?.Handler?.PlatformView is OpenHarmonyView gridPlatform)
{
    var gridCells = gridPlatform.ViewChildren.OfType<View>().ToList();
    var frames = gridCells.Take(4).Select(v => v.Frame).ToList();
    Console.WriteLine($"[verify] grid cells={gridCells.Count} span=3 first4=[{string.Join(" ", frames.Select(f => $"{f.X:0},{f.Y:0},{f.Width:0}x{f.Height:0}"))}]");
}

// W22-14: SecureStorage / AppInfo / DeviceInfo / VersionTracking.
await SecureStorage.Default.SetAsync("verify.secret", "s3cr3t");
Console.WriteLine($"[verify] secure storage read='{await SecureStorage.Default.GetAsync("verify.secret")}'");
SecureStorage.Default.Remove("verify.secret");
Console.WriteLine($"[verify] secure storage after remove='{await SecureStorage.Default.GetAsync("verify.secret") ?? "<null>"}'");
Console.WriteLine($"[verify] appinfo package='{AppInfo.Current.PackageName}' version='{AppInfo.Current.VersionString}' device='{DeviceInfo.Current.Platform}/{DeviceInfo.Current.Idiom}'");
VersionTracking.Default.Track();
Console.WriteLine($"[verify] version tracking firstEver={VersionTracking.Default.IsFirstLaunchEver} previous='{VersionTracking.Default.PreviousVersion}' launches ok");

// Gap 1c assertions (swipe).
var swipeCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "swipe me");
if (swipeCtl is not null)
{
    Rect sf = swipeCtl.Frame;
    float sy = (float)(sf.Y + sf.Height / 2);
    host.HandleTouch(true, false, (float)(sf.X + sf.Width - 60), sy);
    host.HandleMove((float)(sf.X + 60), sy);
    host.HandleTouch(false, true, (float)(sf.X + 60), sy);
    Console.WriteLine($"[verify] swipe gesture direction={gestures.LastSwipe} (threshold 30, drag from x={sf.Right - 60:0} to {sf.X + 60:0})");
}

// Gap 1d: SwipeView reveals its right items on a left drag and activates them.
var swipeRow = root.Children.OfType<SwipeView>().FirstOrDefault();
if (swipeRow is not null)
{
    var swipePlatform = (OpenHarmonyView)swipeRow.Handler!.PlatformView!;
    RectF swipeFrame = swipeRow.Frame;
    Console.WriteLine($"[verify] swipeview items={swipePlatform.SwipeItems.Count} frame={swipeFrame} open={swipePlatform.IsSwipeOpen}");
    float swipeRowY = (float)(swipeFrame.Y + swipeFrame.Height / 2);
    host.HandleTouch(true, false, (float)(swipeFrame.Right - 40), swipeRowY);
    host.HandleMove((float)(swipeFrame.X + 40), swipeRowY);
    host.HandleTouch(false, true, (float)(swipeFrame.X + 40), swipeRowY);
    Console.WriteLine($"[verify] swipeview after drag open={swipePlatform.IsSwipeOpen} virtual={((ISwipeView)swipeRow).IsOpen}");
    RectF swipeItemRect = swipePlatform.SwipeItemRect(0);
    host.HandleTouch(true, false, swipeItemRect.Center.X, swipeItemRect.Center.Y);
    host.HandleTouch(false, true, swipeItemRect.Center.X, swipeItemRect.Center.Y);
    Console.WriteLine($"[verify] swipeview activated clicked={gestures.SwipeViewClicked} invoked={gestures.SwipeViewInvoked} open={swipePlatform.IsSwipeOpen}");
}

// Gap 1d: RefreshView pull triggers the refresh.
var refreshRow = root.Children.OfType<RefreshView>().FirstOrDefault();
if (refreshRow is not null)
{
    var refreshPlatform = (OpenHarmonyView)refreshRow.Handler!.PlatformView!;
    RectF refreshFrame = refreshRow.Frame;
    Console.WriteLine($"[verify] refreshview frame={refreshFrame} refreshing={refreshPlatform.IsRefreshing} runs={gestures.RefreshRuns}");
    float refreshX = (float)(refreshFrame.X + refreshFrame.Width / 2);
    host.HandleTouch(true, false, refreshX, (float)(refreshFrame.Y + 30));
    host.HandleMove(refreshX, (float)(refreshFrame.Y + 130));
    host.HandleTouch(false, true, refreshX, (float)(refreshFrame.Y + 130));
    Console.WriteLine($"[verify] refreshview after pull platform={refreshPlatform.IsRefreshing} virtual={refreshRow.IsRefreshing} runs={gestures.RefreshRuns}");
    refreshRow.IsRefreshing = false;
    host.Arrange(1080, 1920);
    Console.WriteLine($"[verify] refreshview after reset platform={refreshPlatform.IsRefreshing} virtual={refreshRow.IsRefreshing}");
}

// Gap 2: sensor kit wiring (device readings need real hardware).
try
{
    var accelerometer = Accelerometer.Default;
    Console.WriteLine($"[verify] sensors accel={accelerometer.GetType().Name} gyro={Gyroscope.Default.GetType().Name} supported={accelerometer.IsSupported}");
    accelerometer.ReadingChanged += (_, _) => { };
    Console.WriteLine($"[verify] sensors monitoring={accelerometer.IsMonitoring} after start attempt");
    accelerometer.Stop();
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] sensors default unavailable ({ex.GetType().Name})");
}

// Gap 2: the remaining Essentials sensor interfaces installed by the slice (desktop has no host
// library, so every IsSupported probe must answer false instead of throwing).
var magnetometerDefault = Magnetometer.Default;
var compassDefault = Compass.Default;
var barometerDefault = Barometer.Default;
var orientationDefault = OrientationSensor.Default;
Console.WriteLine($"[verify] sensors extra magnetometer={magnetometerDefault.GetType().Name} compass={compassDefault.GetType().Name} barometer={barometerDefault.GetType().Name} orientation={orientationDefault.GetType().Name} supported={magnetometerDefault.IsSupported}");

// Orientation is wired to SENSOR_TYPE_ROTATION_VECTOR (259): the host forwards four components
// (x, y, z, w) and the managed plumbing maps them onto OrientationSensorData unchanged, with no
// reconstructed scalar part. Off-device there is no host library, so invoke the managed callback
// the native listener calls; going through the public delegate type also pins the six-parameter
// native signature.
var orientationProbe = OpenHarmonyOrientationSensor.Instance;
Microsoft.Maui.Devices.Sensors.OrientationSensorData? rotationVectorReading = null;
void OnRotationVector(object? sender, Microsoft.Maui.Devices.Sensors.OrientationSensorChangedEventArgs e)
    => rotationVectorReading = e.Reading;
orientationProbe.ReadingChanged += OnRotationVector;
var onReadingMethod = typeof(OpenHarmonySensors).GetMethod("OnReading",
    System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
var sensorCallback = (OpenHarmonySensors.SensorCallback)Delegate.CreateDelegate(typeof(OpenHarmonySensors.SensorCallback), onReadingMethod);
sensorCallback(OpenHarmonySensors.OrientationType, 0.5f, -0.25f, 0.125f, 0.75f, 123456L);
orientationProbe.ReadingChanged -= OnRotationVector;
bool rotationVectorOk = OpenHarmonySensors.OrientationType == 259 && rotationVectorReading is not null &&
    rotationVectorReading.Value.Orientation.X == 0.5f && rotationVectorReading.Value.Orientation.Y == -0.25f &&
    rotationVectorReading.Value.Orientation.Z == 0.125f && rotationVectorReading.Value.Orientation.W == 0.75f;
Console.WriteLine($"[verify] sensors rotation vector type={OpenHarmonySensors.OrientationType} reading=({rotationVectorReading?.Orientation.X}, {rotationVectorReading?.Orientation.Y}, {rotationVectorReading?.Orientation.Z}, {rotationVectorReading?.Orientation.W}) unchanged={rotationVectorOk}");
if (!rotationVectorOk)
{
    throw new InvalidOperationException("the rotation-vector reading did not reach OrientationSensorData unchanged");
}

// Gap 2: haptic feedback over the host's NDK vibration export (ohos_host_vibrate ->
// OH_Vibrator_PlayVibration). Desktop builds have no libopenharmonyhost.so, so IsSupported
// must answer false and Perform(Click/LongPress) must degrade without throwing.
var hapticsDefault = HapticFeedback.Default;
Console.WriteLine($"[verify] haptics default is OpenHarmony={hapticsDefault is OpenHarmonyHapticFeedback} ({hapticsDefault.GetType().Name})");
bool hapticClickReturned = false;
bool hapticLongPressReturned = false;
try
{
    hapticsDefault.Perform(HapticFeedbackType.Click);
    hapticClickReturned = true;
    hapticsDefault.Perform(HapticFeedbackType.LongPress);
    hapticLongPressReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] haptics perform threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] haptics Perform(Click/LongPress) degraded without throwing={hapticClickReturned}/{hapticLongPressReturned}");
Console.WriteLine($"[verify] haptics IsSupported={hapticsDefault.IsSupported} static={HapticFeedback.IsSupported} (false without the host library)");

// Gap 2: app theme following over the ArkUI colour-mode bridge (Index.ets Environment.envProp
// 'colorMode' + @Watch -> host.notifyTheme -> ohos_host_theme_set_listener -> this handler).
// Desktop has no host library, so Register() must be a guarded no-op; the managed handler is
// then exercised directly (dark -> UserAppTheme/RequestedTheme Dark, light -> Light, restored).
bool themeRegisterReturned = false;
try
{
    OpenHarmonyTheme.Register();
    themeRegisterReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] theme register threw {ex.GetType().Name}: {ex.Message}");
}
var themeBefore = Application.Current!.UserAppTheme;
OpenHarmonyTheme.OnPlatformThemeChanged(true);
bool themeDark = Application.Current.UserAppTheme == AppTheme.Dark && Application.Current.RequestedTheme == AppTheme.Dark;
OpenHarmonyTheme.OnPlatformThemeChanged(false);
bool themeLight = Application.Current.UserAppTheme == AppTheme.Light && Application.Current.RequestedTheme == AppTheme.Light;
Application.Current.UserAppTheme = themeBefore;
Console.WriteLine($"[verify] theme register degraded without throwing={themeRegisterReturned} (no host library)");
Console.WriteLine($"[verify] theme bridge dark={themeDark} light={themeLight} restored={Application.Current.UserAppTheme == themeBefore} last={OpenHarmonyTheme.LastIsDark}");

// Gap 2: notification kit (the shell publishes on device; desktop degrades to false).
Console.WriteLine($"[verify] notifications show(on desktop)={OpenHarmonyNotifications.Show("Title", "Text")}");

// Gap 2: TextToSpeech over the Speech Kit bridge (the OpenHarmony SDK ships no speech module,
// so the shell sink answers unavailable and the managed side must degrade without throwing).
var ttsDefault = Microsoft.Maui.Media.TextToSpeech.Default;
Console.WriteLine($"[verify] tts default is OpenHarmony={ttsDefault is OpenHarmonyTextToSpeech} ({ttsDefault.GetType().Name})");
bool ttsSpeakReturned = false;
try
{
    await ttsDefault.SpeakAsync("verify speech");
    ttsSpeakReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] tts speak threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] tts speak degraded without throwing={ttsSpeakReturned}");
var ttsLocales = (await ttsDefault.GetLocalesAsync()).ToList();
Console.WriteLine($"[verify] tts locales={ttsLocales.Count} first='{ttsLocales.FirstOrDefault()?.Id}' language='{ttsLocales.FirstOrDefault()?.Language}'");

// Gap 3: camera capture goes through the shell picker (device only).
Console.WriteLine($"[verify] media captureSupported={MediaPicker.Default.IsCaptureSupported} capture={await MediaPicker.Default.CapturePhotoAsync() is null} (null off-device)");

// Limitations re-audit: pointer gestures.
var pointerCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "hover me");
if (pointerCtl is not null)
{
    host.Arrange(1080, 1920);
    Rect pf = pointerCtl.Frame;
    float px = (float)(pf.X + pf.Width / 2);
    float py = (float)(pf.Y + pf.Height / 2);
    host.HandleTouch(true, false, px, py);
    host.HandleTouch(false, true, px, py);
    Console.WriteLine($"[verify] pointer entered={gestures.PointerEntered} pressed={gestures.PointerPressed} released={gestures.PointerReleased} exited={gestures.PointerExited}");
    // pointer move test (mouse hover arrives as a touch move)
    gestures.PointerEntered = gestures.PointerExited = false;
    host.HandleMove(px, py);
    bool movedIn = gestures.PointerEntered;
    host.HandleMove(10f, 1500f);
    Console.WriteLine($"[verify] pointer hover entered={movedIn} exited={gestures.PointerExited}");
}

// Limitations re-audit: pinch gestures (managed half, public IPinchGestureController).
var pinchCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pinch me");
if (pinchCtl is not null)
{
    host.Arrange(1080, 1920);
    Rect kf = pinchCtl.Frame;
    float kx = (float)(kf.X + kf.Width / 2);
    float ky = (float)(kf.Y + kf.Height / 2);
    OpenHarmonyPinch.Dispatch(pinchCtl, 0, 1.0, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 1, 1.5, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 1, 2.0, kx, ky);
    OpenHarmonyPinch.Dispatch(pinchCtl, 2, 1.0, kx, ky);
    Console.WriteLine($"[verify] pinch events={gestures.PinchLog.Trim()}");
}

// Batch D1: visual diagnostics overlay.
OpenHarmonyDiagnostics.Enabled = true;
host.Arrange(1080, 1920);
host.Render();
Console.WriteLine($"[verify] diagnostics outlines={OpenHarmonyDiagnostics.OutlinesDrawn} enabled={OpenHarmonyDiagnostics.Enabled}");
OpenHarmonyDiagnostics.Enabled = false;
Console.WriteLine($"[verify] a11y nodes={OpenHarmonyAccessibility.Nodes.Count} buttons={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "button")} texts={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "text")}");
var a11ySample = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Text == "hover me");
Console.WriteLine($"[verify] a11y sample text='{a11ySample?.Text}' role={a11ySample?.Role} focusable={a11ySample?.IsFocusable} bounds={a11ySample?.Bounds.Width:0}x{a11ySample?.Bounds.Height:0}");
Console.WriteLine($"[verify] a11y publish off-device={OpenHarmonyAccessibility.LastPublishedCount} (no throw)");
Console.WriteLine($"[verify] a11y heading role={OpenHarmonyAccessibility.Nodes.Count(n => n.Role == "header")} hints={OpenHarmonyAccessibility.Nodes.Count(n => !string.IsNullOrEmpty(n.Hint))}");
// Change a label's text and re-render: the diff should report a text update.
var a11yTextCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "hover me");
if (a11yTextCtl is not null)
{
    a11yTextCtl.Text = "hover me v2";
    host.Render();
    Console.WriteLine($"[verify] a11y events after text change={OpenHarmonyAccessibility.PendingEventCount} (text update bit={(OpenHarmonyAccessibility.PendingEventCount & 0x10) != 0})");
}

// D2: accessibility action routing (CLICK -> normal tap path).
var a11yTapNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Text == "tap me" && n.Role == "text");
if (a11yTapNode is not null)
{
    int tapsBefore = gestures.TapCount;
    bool clickHandled = host.HandleAccessibilityAction(a11yTapNode.Id, 0x10);
    Console.WriteLine($"[verify] a11y click handled={clickHandled} taps {tapsBefore}->{gestures.TapCount}");
}

// Audit: an unchanged frame must not re-publish the tree to the host.
if (OpenHarmonyAccessibility.Nodes.Count > 0)
{
    host.Render();
    int skippedBefore = OpenHarmonyAccessibility.FramesSkipped;
    host.Render();
    Console.WriteLine($"[verify] a11y skip unchanged frame: wouldPublish={OpenHarmonyAccessibility.WouldPublish} skipped {skippedBefore}->{OpenHarmonyAccessibility.FramesSkipped}");
}
Console.WriteLine($"[verify] a11y actions text=[{string.Join(",", OpenHarmonyAccessibility.ActionsFor("text"))}] input=[{string.Join(",", OpenHarmonyAccessibility.ActionsFor("textInput"))}]");

// Alert overlay: DisplayAlert shows in the compositor and a button tap completes it.
var alertTask = page.DisplayAlert("Alert title", "Alert message", "OK", "Cancel");
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] alert shown={OpenHarmonyAlertHost.IsVisible} pending={!alertTask.IsCompleted}");
var acceptRect = OpenHarmonyAlertHost.AcceptRect;
bool alertDown = host.HandleTouch(true, false, acceptRect.Center.X, acceptRect.Center.Y);
bool alertUp = host.HandleTouch(false, true, acceptRect.Center.X, acceptRect.Center.Y);
Console.WriteLine($"[verify] alert tap handled={alertDown}/{alertUp} visible={OpenHarmonyAlertHost.IsVisible} result={(alertTask.IsCompleted ? (await alertTask).ToString() : "pending")}");

// Action sheet overlay: options resolve the sheet.
var sheetTask = page.DisplayActionSheet("Pick one", "Cancel", null, "Alpha", "Beta");
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] sheet options={OpenHarmonyAlertHost.Current?.Options.Count} title='{OpenHarmonyAlertHost.Current?.Title}'");
var rowRect = OpenHarmonyAlertHost.OptionRect(1);
host.HandleTouch(true, false, rowRect.Center.X, rowRect.Center.Y);
host.HandleTouch(false, true, rowRect.Center.X, rowRect.Center.Y);
Console.WriteLine($"[verify] sheet result={(sheetTask.IsCompleted ? await sheetTask : "pending")} visible={OpenHarmonyAlertHost.IsVisible}");

// Prompt overlay: keyboard text edits it and Accept resolves the string.
var promptTask = page.DisplayPromptAsync("Name", "Type it");
host.Arrange(1080, 1920);
OpenHarmonyAlertHost.PromptAppend("hello");
OpenHarmonyAlertHost.PromptAppend("!");
Console.WriteLine($"[verify] prompt text='{OpenHarmonyAlertHost.Current?.PromptText}' pending={!promptTask.IsCompleted}");
var promptAccept = OpenHarmonyAlertHost.AcceptRect;
host.HandleTouch(true, false, promptAccept.Center.X, promptAccept.Center.Y);
host.HandleTouch(false, true, promptAccept.Center.X, promptAccept.Center.Y);
Console.WriteLine($"[verify] prompt result={(promptTask.IsCompleted ? (await promptTask) ?? "<null>" : "pending")}");

// Audit batch 2 assertions.
var graphicsCtl = root.Children.OfType<GraphicsView>().FirstOrDefault();
if (graphicsCtl?.Handler?.PlatformView is OpenHarmonyView graphicsPlatform)
{
    var rendererForGraphics = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
    rendererForGraphics.Render(navRoot, 1080, 1920);
    Console.WriteLine($"[verify] graphicsview drawCalled={gestures.Drawable?.DrawCalls} frame={graphicsCtl.Frame}");
    Rect gf = graphicsCtl.Frame;
    host.HandleTouch(true, false, (float)(gf.X + 10), (float)(gf.Y + 10));
    host.HandleTouch(false, true, (float)(gf.X + 10), (float)(gf.Y + 10));
    Console.WriteLine($"[verify] graphicsview touchCalls={gestures.Drawable?.TouchCalls}");
}
var contentViewCtl = root.Children.OfType<ContentView>().FirstOrDefault();
if (contentViewCtl is not null)
{
    var inner = contentViewCtl.Content as Label;
    Console.WriteLine($"[verify] contentview frame={contentViewCtl.Frame} inner={inner?.Frame} text='{inner?.Text}'");
}
var imageButtonCtl = root.Children.OfType<ImageButton>().FirstOrDefault();
if (imageButtonCtl?.Handler?.PlatformView is OpenHarmonyView imageButtonPlatform)
{
    Console.WriteLine($"[verify] imagebutton bytes={imageButtonPlatform.ImageBytes?.Length ?? 0}");
}

// Modal pages: pushed modals take over rendering.
var controlsWindow = (Microsoft.Maui.Controls.Window)host.Window!;
await controlsWindow.Navigation.PushModalAsync(new ContentPage { Title = "Modal", Content = new Label { Text = "modal page" } }, false);
await Task.Delay(100);
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] modal describe root: {(host.Describe().Split('\n').FirstOrDefault() ?? "").Trim()}");
await controlsWindow.Navigation.PopModalAsync(false);
await Task.Delay(100);
host.Arrange(1080, 1920);
Console.WriteLine($"[verify] after pop root: {(host.Describe().Split('\n').FirstOrDefault() ?? "").Trim()}");

// Audit batch assertions.
var boxCtl = root.Children.OfType<BoxView>().FirstOrDefault();
if (boxCtl?.Handler?.PlatformView is OpenHarmonyView boxPlatform)
{
    Console.WriteLine($"[verify] boxview frame={boxCtl.Frame} background={(boxPlatform.Background is not null)}");
}
var indicatorCtl = root.Children.OfType<IndicatorView>().FirstOrDefault();
if (indicatorCtl?.Handler?.PlatformView is OpenHarmonyView indicatorPlatform)
{
    Console.WriteLine($"[verify] indicator count={indicatorPlatform.IndicatorCount} position={indicatorPlatform.IndicatorPosition}");
}
var frameCtl = root.Children.OfType<Frame>().FirstOrDefault();
if (frameCtl is not null)
{
    var innerLabel = frameCtl.Content as Label;
    Console.WriteLine($"[verify] frame frame={frameCtl.Frame} inner={innerLabel?.Frame} text='{innerLabel?.Text}'");
}
var editorCtl = root.Children.OfType<Editor>().FirstOrDefault();
if (editorCtl is not null)
{
    Rect ef2 = editorCtl.Frame;
    host.HandleTouch(true, false, (float)(ef2.X + 20), (float)(ef2.Y + 20));
    host.HandleTouch(false, true, (float)(ef2.X + 20), (float)(ef2.Y + 20));
    editorCtl.Text = "editor text";
    var editorPlatform = (OpenHarmonyView)editorCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] editor focused={editorPlatform.IsFocused} text='{editorPlatform.Text}'");
}
var xamlPage = new verify.XamlPage();
OpenHarmonyHandlerConnector.ConnectTree(xamlPage);
xamlPage.Measure(1080, 600);
xamlPage.Arrange(new Rect(0, 0, 1080, 600));
Console.WriteLine($"[verify] xaml page label='{xamlPage.FindByName<Label>("XamlTitle")?.Text}' button='{xamlPage.FindByName<Button>("XamlButton")?.Text}' frame={xamlPage.FindByName<Label>("XamlTitle")?.Frame}");

// W22-15: grouped collection + carousel loop.
var groupedCtl = root.Children.OfType<CollectionView>().FirstOrDefault(c => c.IsGrouped);
if (groupedCtl?.Handler?.PlatformView is OpenHarmonyView groupedPlatform)
{
    var rows = groupedPlatform.ViewChildren.OfType<View>()
        .Select(v => (v.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "?")
        .ToList();
    Console.WriteLine($"[verify] grouped rows={rows.Count} [{string.Join(", ", rows.Take(6))}] content={groupedPlatform.ScrollContentHeight:0}");
}

var loopCtl = root.Children.OfType<CarouselView>().FirstOrDefault();
if (loopCtl?.Handler?.PlatformView is OpenHarmonyView loopPlatform)
{
    loopCtl.Position = 2;
    loopCtl.Handler!.UpdateValue("Position");
    Rect lf2 = loopCtl.Frame;
    float ly = (float)(lf2.Y + lf2.Height / 2);
    rendererForShell.HandleTouch(navRoot, true, false, (float)(lf2.X + lf2.Width - 40), ly);
    rendererForShell.HandleMove((float)(lf2.X + lf2.Width - 220), ly);
    rendererForShell.HandleTouch(navRoot, false, true, (float)(lf2.X + lf2.Width - 220), ly);
    string currentItem = (loopPlatform.ViewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "<none>";
    Console.WriteLine($"[verify] carousel loop position={loopCtl.Position} item='{currentItem}' (wrapped from 2)");
}

// W22-17: clipboard / connectivity / launcher / browser / share.
await Clipboard.Default.SetTextAsync("clip-text");
Console.WriteLine($"[verify] clipboard hasText={Clipboard.Default.HasText} text='{await Clipboard.Default.GetTextAsync()}'");
await Clipboard.Default.SetTextAsync(null);
Console.WriteLine($"[verify] clipboard after clear hasText={Clipboard.Default.HasText}");
Console.WriteLine($"[verify] connectivity access={Connectivity.Current.NetworkAccess} profiles={Connectivity.Current.ConnectionProfiles.Count()}");
Console.WriteLine($"[verify] launcher open={await Launcher.Default.TryOpenAsync(new Uri("https://example.com"))} browser open={await Browser.Default.OpenAsync(new Uri("https://example.com"))}");
await Share.Default.RequestAsync(new ShareTextRequest { Text = "hello" });
Console.WriteLine("[verify] share request completed (no host library -> degraded, documented)");

// Gap 4: app-launching essentials (Launcher/Browser/Share) over the ArkTS ability bridge
// (ohos_host_ability_start -> shell registerAbilitySink -> UIAbilityContext.startAbility).
// On desktop there is no libopenharmonyhost.so, so every call must degrade to false without
// throwing, and the three Essentials defaults must be this slice's implementations.
var launcherDefault = Launcher.Default;
var browserDefault = Browser.Default;
var shareDefault = Share.Default;
Console.WriteLine($"[verify] intents defaults launcher={launcherDefault.GetType().Name} browser={browserDefault.GetType().Name} share={shareDefault.GetType().Name}");
Console.WriteLine($"[verify] intents defaults are OpenHarmony={launcherDefault is OpenHarmonyLauncher} browser={browserDefault is OpenHarmonyBrowser} share={shareDefault is OpenHarmonyShare}");
bool canOpen = false;
bool launcherOpen = false;
bool launcherTryOpen = false;
try
{
    canOpen = await launcherDefault.CanOpenAsync(new Uri("https://example.com"));
    launcherOpen = await launcherDefault.OpenAsync(new Uri("https://example.com"));
    launcherTryOpen = await launcherDefault.TryOpenAsync(new Uri("https://example.com"));
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents launcher threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents launcher degraded without throwing canOpen={canOpen} open={launcherOpen} tryOpen={launcherTryOpen}");
bool browserOpen = false;
try
{
    browserOpen = await browserDefault.OpenAsync(new Uri("https://example.com"), BrowserLaunchMode.SystemPreferred);
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents browser threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents browser degraded without throwing={browserOpen}");
bool openFile = false;
try
{
    openFile = await launcherDefault.OpenAsync(new OpenFileRequest { File = new ReadOnlyFile(imagePath) });
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents launcher file threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents launcher file request degraded without throwing open={openFile}");
bool shareTextReturned = false;
bool shareFileReturned = false;
try
{
    await shareDefault.RequestAsync(new ShareTextRequest { Text = "verify share" });
    shareTextReturned = true;
    await shareDefault.RequestAsync(new ShareFileRequest { File = new ShareFile(imagePath) });
    shareFileReturned = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] intents share threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] intents share degraded without throwing text={shareTextReturned} file={shareFileReturned}");

// W22-12: ListView (virtualized cells) + CarouselView swipe.
var listCtl = root.Children.OfType<ListView>().FirstOrDefault();
if (listCtl?.Handler?.PlatformView is OpenHarmonyView listPlatform)
{
    var cells = listPlatform.ViewChildren.OfType<View>().ToList();
    var firstCell = cells.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] listview materialized={cells.Count} of 12 first='{firstCell?.Text}' content={listPlatform.ScrollContentHeight:0}");
    Rect lf = listCtl.Frame;
    float lx = (float)(lf.X + lf.Width / 2);
    rendererForShell.HandleTouch(navRoot, true, false, lx, (float)(lf.Y + lf.Height - 30));
    rendererForShell.HandleMove(lx, (float)(lf.Y + 30));
    rendererForShell.HandleTouch(navRoot, false, true, lx, (float)(lf.Y + 30));
    var after = listPlatform.ViewChildren.OfType<View>().ToList();
    Console.WriteLine($"[verify] listview after drag offset={listPlatform.ScrollOffsetY:0} materialized={after.Count}");
}

var carouselCtl = root.Children.OfType<CarouselView>().FirstOrDefault();
if (carouselCtl?.Handler?.PlatformView is OpenHarmonyView carouselPlatform)
{
    string Current() => (carouselPlatform.ViewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView)?.Text ?? "<none>";
    Console.WriteLine($"[verify] carousel position={carouselCtl.Position} item='{Current()}'");
    Rect cf2 = carouselCtl.Frame;
    float cy2 = (float)(cf2.Y + cf2.Height / 2);
    rendererForShell.HandleTouch(navRoot, true, false, (float)(cf2.X + cf2.Width - 40), cy2);
    rendererForShell.HandleMove((float)(cf2.X + cf2.Width - 200), cy2);
    rendererForShell.HandleTouch(navRoot, false, true, (float)(cf2.X + cf2.Width - 200), cy2);
    Console.WriteLine($"[verify] carousel after swipe position={carouselCtl.Position} item='{Current()}'");
}

// W22-9: flyout page.
var rendererForFlyout = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var flyoutFlyout = new ContentPage { Title = "menu", Content = new Label { Text = "flyout content" } };
var flyoutDetail = new ContentPage { Title = "detail", Content = new Label { Text = "detail content" } };
var flyoutPage = new FlyoutPage { Flyout = flyoutFlyout, Detail = flyoutDetail, IsPresented = false };
OpenHarmonyHandlerConnector.ConnectTree(flyoutPage);
flyoutPage.Measure(1080, 1920);
flyoutPage.Arrange(new Rect(0, 0, 1080, 1920));
if (flyoutPage.Handler?.PlatformView is OpenHarmonyView flyoutPlatform)
{
    Console.WriteLine($"[verify] flyout initial presented={flyoutPlatform.FlyoutPresented} width={flyoutPlatform.FlyoutWidth:0} detailLabel={((View)flyoutDetail.Content!).Frame}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 20, 20);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 20, 20);
    Console.WriteLine($"[verify] flyout after hamburger presented={flyoutPage.IsPresented} flyoutLabel={((View)flyoutFlyout.Content!).Frame}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 100, 400);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 100, 400);
    Console.WriteLine($"[verify] flyout after panel tap presented={flyoutPage.IsPresented}");
    rendererForFlyout.HandleTouch(flyoutPage, true, false, 800, 400);
    rendererForFlyout.HandleTouch(flyoutPage, false, true, 800, 400);
    Console.WriteLine($"[verify] flyout after outside tap presented={flyoutPage.IsPresented}");
}

// W22-7b: tabbed page.
Console.WriteLine($"[verify] Application.Current={Application.Current?.GetType().Name ?? "null"} dispatcher={Application.Current?.Dispatcher?.GetType().Name ?? "null"}");
var tabOne = new ContentPage { Title = "One", Content = new Label { Text = "tab one" } };
var tabTwo = new ContentPage { Title = "Two", Content = new Label { Text = "tab two" } };
var tabbed = new TabbedPage { Children = { tabOne, tabTwo } };
OpenHarmonyHandlerConnector.ConnectTree(tabbed);
tabbed.Measure(1080, 1920);
tabbed.Arrange(new Rect(0, 0, 1080, 1920));
var renderer = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
if (tabbed.Handler?.PlatformView is OpenHarmonyView tabPlatform)
{
    Console.WriteLine($"[verify] tabbed titles=[{string.Join(",", tabPlatform.TabTitles)}] selected={tabPlatform.SelectedTab} current='{tabbed.CurrentPage?.Title}'");
    double tabY = tabbed.Frame.Height - OpenHarmonyView.TabBarHeight / 2;
    double tabX = tabbed.Frame.Width * 0.75;
    renderer.HandleTouch(tabbed, true, false, (float)tabX, (float)tabY);
    renderer.HandleTouch(tabbed, false, true, (float)tabX, (float)tabY);
    Console.WriteLine($"[verify] tabbed after tap selected={tabPlatform.SelectedTab} current='{tabbed.CurrentPage?.Title}'");
    var contentFrame = ((View)tabTwo.Content!).Frame;
    Console.WriteLine($"[verify] tabbed content frame={contentFrame} (page arranged above the bar)");
}

// W22-6: gestures, selection, transforms.
var tapCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "tap me");
if (tapCtl is not null)
{
    Rect f = tapCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 20), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] tap gesture count={gestures.TapCount}");
}

var panCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pan me");
if (panCtl is not null)
{
    Rect f = panCtl.Frame;
    float x = (float)(f.X + 20);
    host.HandleTouch(true, false, x, (float)(f.Y + 4));
    host.HandleMove(x, (float)(f.Y + 30));
    host.HandleMove(x, (float)(f.Y + 54));
    host.HandleTouch(false, true, x, (float)(f.Y + 54));
    Console.WriteLine($"[verify] pan gesture started={gestures.PanStarted} totalY={gestures.PanTotalY:0.#} completed={gestures.PanCompleted}");
}

// Gap 1e: drag-and-drop gestures (long press + move, drop target hit testing). The recognizers
// are attached to labels already arranged near the top of the page so this check does not shift
// the frames the rest of the suite asserts.
var dragSourceCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "swipe me");
var dropTargetCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "pinch me");
if (dragSourceCtl is not null && dropTargetCtl is not null)
{
    var dragRecognizer = new Microsoft.Maui.Controls.DragGestureRecognizer();
    dragRecognizer.DragStarting += (_, _) => gestures.DragStartingCount++;
    dragRecognizer.DropCompleted += (_, e) =>
    {
        gestures.DropCompletedCount++;
        gestures.LastDropResult = gestures.DropResultOf(e);
    };
    dragSourceCtl.GestureRecognizers.Add(dragRecognizer);

    var dropRecognizer = new Microsoft.Maui.Controls.DropGestureRecognizer();
    dropRecognizer.DragOver += (_, e) =>
    {
        gestures.DragOverCount++;
        gestures.LastDragOverText = e.Data.Text;
    };
    dropRecognizer.DragLeave += (_, _) => gestures.DragLeaveCount++;
    dropRecognizer.Drop += (_, e) =>
    {
        gestures.DropCount++;
        gestures.DroppedText = e.Data.GetTextAsync().GetAwaiter().GetResult();
    };
    dropTargetCtl.GestureRecognizers.Add(dropRecognizer);

    host.Arrange(1080, 1920);
    Rect sourceFrame = dragSourceCtl.Frame;
    Rect targetFrame = dropTargetCtl.Frame;
    float sx = (float)(sourceFrame.X + sourceFrame.Width / 2);
    float sy = (float)(sourceFrame.Y + sourceFrame.Height / 2);
    float tx = (float)(targetFrame.X + targetFrame.Width / 2);
    float ty = (float)(targetFrame.Y + targetFrame.Height / 2);

    // (1) Long press + move starts the drag; entering the target raises DragOver, leaving and
    //     re-entering raises DragLeave/DragOver, and releasing over it delivers Drop with the
    //     source text, then DropCompleted on the source.
    gestures.DragStartingCount = gestures.DragOverCount = gestures.DragLeaveCount = 0;
    gestures.DropCount = gestures.DropCompletedCount = 0;
    gestures.LastDragOverText = gestures.DroppedText = null;
    bool dd = host.HandleTouch(true, false, sx, sy);
    await Task.Delay(600);
    bool dm = host.HandleMove(sx + 24, sy);
    bool dOver = host.HandleMove(tx, ty);
    bool dAway = host.HandleMove(sx, 1900f);
    bool dBack = host.HandleMove(tx, ty);
    bool du = host.HandleTouch(false, true, tx, ty);
    bool dropFlowOk = gestures.DragStartingCount == 1 && gestures.DragOverCount == 2 &&
                      gestures.DragLeaveCount == 1 && gestures.LastDragOverText == "swipe me" &&
                      gestures.DropCount == 1 && gestures.DroppedText == "swipe me" &&
                      gestures.DropCompletedCount == 1;
    Console.WriteLine($"[verify] drag/drop handled={dd}/{dm}/{dOver}/{dAway}/{dBack}/{du} starting={gestures.DragStartingCount} over={gestures.DragOverCount} leave={gestures.DragLeaveCount} drop={gestures.DropCount} text='{gestures.DroppedText}' completed={gestures.DropCompletedCount} assert={dropFlowOk}");
    if (!dropFlowOk)
    {
        throw new InvalidOperationException("drag/drop flow assertion failed");
    }

    // (2) Releasing over nothing raises no Drop and DropCompleted reports no operation (failure).
    gestures.DragStartingCount = gestures.DragOverCount = gestures.DragLeaveCount = 0;
    gestures.DropCount = gestures.DropCompletedCount = 0;
    gestures.DroppedText = null;
    float emptyY = 1900f;
    host.HandleTouch(true, false, sx, sy);
    await Task.Delay(600);
    host.HandleMove(sx + 24, sy);
    host.HandleMove(sx, emptyY);
    host.HandleTouch(false, true, sx, emptyY);
    bool noTargetOk = gestures.DragStartingCount == 1 && gestures.DragOverCount == 0 &&
                      gestures.DropCount == 0 && gestures.DropCompletedCount == 1 &&
                      gestures.LastDropResult == "None";
    Console.WriteLine($"[verify] drag/drop over nothing starting={gestures.DragStartingCount} over={gestures.DragOverCount} drop={gestures.DropCount} completed={gestures.DropCompletedCount} result={gestures.LastDropResult} success=false={noTargetOk}");
    if (!noTargetOk)
    {
        throw new InvalidOperationException("drag/drop over nothing assertion failed");
    }

    // (3) Moving beyond the slop before the long-press window never promotes the press.
    gestures.DragStartingCount = 0;
    host.HandleTouch(true, false, sx, sy);
    host.HandleMove(sx, sy + 24);
    host.HandleMove(sx, sy + 48);
    host.HandleTouch(false, true, sx, sy + 48);
    Console.WriteLine($"[verify] drag/drop early move starting={gestures.DragStartingCount} (no drag before 500 ms) assert={gestures.DragStartingCount == 0}");
    if (gestures.DragStartingCount != 0)
    {
        throw new InvalidOperationException("early-move drag assertion failed");
    }
}

var animatedCtl = root.Children.OfType<Label>().FirstOrDefault(l => l.Text == "transformed");
if (animatedCtl is not null)
{
    Console.WriteLine("[verify] transform: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("transform=")) ?? "<none>").Trim());
}

// W22-5: shapes/border/stepper/radio/search bar.
var shapesRow = root.Children.OfType<HorizontalStackLayout>().FirstOrDefault(l => l.Children.OfType<View>().Any(v => v.GetType().Name == "Rectangle"));
if (shapesRow is not null)
{
    foreach (var shapeView in shapesRow.Children.OfType<View>())
    {
        var platform = shapeView.Handler?.PlatformView as OpenHarmonyView;
        var path = platform?.Shape?.PathForBounds(new Microsoft.Maui.Graphics.RectF(platform.Frame.X, platform.Frame.Y, platform.Frame.Width, platform.Frame.Height));
        string fill = platform?.ShapeFill is Microsoft.Maui.Graphics.SolidPaint sp ? sp.Color.ToHex() : "null";
        Console.WriteLine($"[verify] shape {shapeView.GetType().Name} frame={shapeView.Frame} pathPoints={(path?.Points?.Count() ?? 0)} fill={fill}");
    }
}

var borderCtl = root.Children.OfType<Border>().FirstOrDefault();
if (borderCtl is not null)
{
    var innerLabel = (borderCtl.Content as Label);
    Console.WriteLine($"[verify] border frame={borderCtl.Frame} inner={innerLabel?.Frame} text='{innerLabel?.Text}'");
}

var stepperCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Stepper>().FirstOrDefault();
if (stepperCtl is not null)
{
    Rect f = stepperCtl.Frame;
    float y = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.75), y);
    host.HandleTouch(true, false, (float)(f.X + f.Width * 0.25), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width * 0.25), y);
    Console.WriteLine($"[verify] stepper after +/+/- value={stepperCtl.Value} (virtual)");
}

var radioCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<RadioButton>().FirstOrDefault();
if (radioCtl is not null)
{
    Rect f = radioCtl.Frame;
    host.HandleTouch(true, false, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    host.HandleTouch(false, true, (float)(f.X + 10), (float)(f.Y + f.Height / 2));
    Console.WriteLine($"[verify] radio after tap checked={radioCtl.IsChecked}");
}

var searchCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<SearchBar>().FirstOrDefault();
if (searchCtl is not null)
{
    searchCtl.Text = "hello search";
    var platform = (OpenHarmonyView)searchCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] searchbar text='{platform.Text}' placeholder='{platform.Placeholder}'");
}

// W22-4: collection view items + drag scrolling.
var collectionCtl = root.Children.OfType<CollectionView>()
    .FirstOrDefault(c => !c.IsGrouped && c.ItemsLayout is not GridItemsLayout);
if (collectionCtl is not null && collectionCtl.Handler?.PlatformView is OpenHarmonyView collectionPlatform)
{
    var viewChildren = collectionPlatform.ViewChildren.OfType<View>().ToList();
    var firstLabel = viewChildren.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    var lastLabel = viewChildren.LastOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection materialized={viewChildren.Count} of 20 first='{firstLabel?.Text}' last='{lastLabel?.Text}' content={collectionPlatform.ScrollContentHeight:0}");
    collectionCtl.SelectionChanged += (_, e) => Console.WriteLine($"[verify] collection SelectionChanged='{e.CurrentSelection.FirstOrDefault()}'");
    var itemViews = collectionPlatform.ViewChildren.OfType<View>().ToList();
    if (itemViews.Count > 2)
    {
        Rect itemFrame = itemViews[2].Frame;
        host.HandleTouch(true, false, (float)(itemFrame.X + 20), (float)(itemFrame.Y + 10));
        host.HandleTouch(false, true, (float)(itemFrame.X + 20), (float)(itemFrame.Y + 10));
        var selectedItemView = itemViews[2].Handler?.PlatformView as OpenHarmonyView;
    var unselectedItemView = itemViews[0].Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection tap selected='{collectionCtl.SelectedItem}' highlight={(selectedItemView?.Background is not null)} otherHighlight={(unselectedItemView?.Background is not null)} (itemFrame={itemFrame})");
    }

    Rect cf = collectionCtl.Frame;
    float cx = (float)(cf.X + cf.Width / 2);
    bool cd = host.HandleTouch(true, false, cx, (float)(cf.Y + cf.Height - 40));
    bool cm = host.HandleMove(cx, (float)(cf.Y + 40));
    host.HandleTouch(false, true, cx, (float)(cf.Y + 40));
    var afterDrag = collectionPlatform.ViewChildren.OfType<View>().ToList();
    var afterFirst = afterDrag.FirstOrDefault()?.Handler?.PlatformView as OpenHarmonyView;
    Console.WriteLine($"[verify] collection drag handled={cd}/{cm} offset={collectionPlatform.ScrollOffsetY:0} materialized={afterDrag.Count} first='{afterFirst?.Text}'");
}

// W22-3: navigation page (bar + push/pop).
var navigation = navRoot;
Console.WriteLine("[verify] nav initial: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("nav=")) ?? "<none>").Trim());

var pageTwo = new ContentPage
{
    Title = "Page Two",
    Content = new VerticalStackLayout { Padding = 24, Children = { new Label { Text = "second page", FontSize = 32 } } },
};
try
{
    var pushTask = navigation.PushAsync(pageTwo, false);
    if (await Task.WhenAny(pushTask, Task.Delay(3000)) != pushTask)
    {
        Console.WriteLine("[verify] PushAsync did not complete within 3s");
    }
    else
    {
        Console.WriteLine("[verify] PushAsync completed");
    }
    host.Arrange(1080, 1920);
    Console.WriteLine("[verify] after push: " + (host.Describe().Split('\n').FirstOrDefault(l => l.Contains("nav=")) ?? "<none>").Trim());
    Console.WriteLine("[verify] stack=" + string.Join("/", navigation.Navigation.NavigationStack.Select(p => p.Title)));
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] PushAsync threw {ex.GetType().Name}: {ex.Message}");
}

Rect navFrame = navigation.Frame;
var navPlatform = (OpenHarmonyView)navigation.Handler!.PlatformView!;
bool downHandled = host.HandleTouch(true, false, (float)(navFrame.X + 20), (float)(navFrame.Y + 20));
Console.WriteLine($"[verify] nav down handled={downHandled} canGoBack={navPlatform.CanGoBack} inBack={navPlatform.InBackRegion(20, 20)} pressed={navPlatform.Pressed}");
bool back = host.HandleTouch(false, true, (float)(navFrame.X + 20), (float)(navFrame.Y + 20));

host.Arrange(1080, 1920);
Console.WriteLine($"[verify] back tap handled={back} stack={string.Join("/", navigation.Navigation.NavigationStack.Select(p => p.Title))}");

// Gap 1d: toolbar items draw in the navigation bar and activate on tap.
int toolbarClicks = 0;
var toolbarPage = navRoot.CurrentPage;
toolbarPage.ToolbarItems.Add(new ToolbarItem { Text = "Sync", Command = new Command(() => toolbarClicks++) });
host.Arrange(1080, 1920);
var toolbarNav = (OpenHarmonyView)navRoot.Handler!.PlatformView!;
RectF syncRect = toolbarNav.ToolbarItemRect(0);
Console.WriteLine($"[verify] toolbar items={toolbarNav.ToolbarItems.Count} rect={syncRect}");
host.HandleTouch(true, false, syncRect.Center.X, syncRect.Center.Y);
host.HandleTouch(false, true, syncRect.Center.X, syncRect.Center.Y);
Console.WriteLine($"[verify] toolbar clicks={toolbarClicks} pressed={toolbarNav.Pressed}");

// Value controls: tap the check box / switch, drag the slider.
void TapView(View view)
{
    Rect f = view.Frame;
    float cx = (float)(f.X + f.Width / 2);
    float cy = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, cx, cy);
    host.HandleTouch(false, true, cx, cy);
}

var checkBoxCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<CheckBox>().FirstOrDefault();
if (checkBoxCtl is not null)
{
    TapView(checkBoxCtl);
    var platform = (OpenHarmonyView)checkBoxCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] checkbox after tap checked={platform.IsChecked} (virtual={checkBoxCtl.IsChecked})");
}

var switchCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Switch>().FirstOrDefault();
if (switchCtl is not null)
{
    TapView(switchCtl);
    var platform = (OpenHarmonyView)switchCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] switch after tap on={platform.IsOn} (virtual={switchCtl.IsToggled})");
}

var sliderCtl = root.Children.OfType<HorizontalStackLayout>().SelectMany(l => l.Children).OfType<Slider>().FirstOrDefault();
if (sliderCtl is not null)
{
    Rect f = sliderCtl.Frame;
    float y = (float)(f.Y + f.Height / 2);
    host.HandleTouch(true, false, (float)(f.X + 10), y);
    Console.WriteLine($"[verify] slider move x={(float)(f.X + f.Width - 10):0} range=({f.X + 10:0},{f.X + f.Width - 10:0})");
    bool m = host.HandleMove((float)(f.X + f.Width - 10), y);
    host.HandleTouch(false, true, (float)(f.X + f.Width - 10), y);
    var platform = (OpenHarmonyView)sliderCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] slider frame={f} fraction={((OpenHarmonyView)sliderCtl.Handler!.PlatformView!).SliderFraction:0.##}");
    Console.WriteLine($"[verify] slider drag handled={m} value={sliderCtl.Value:0.#} (virtual={sliderCtl.Value:0.#}, platform={platform.SliderValue:0.#})");
}

var spinnerCtl = root.Children.OfType<ActivityIndicator>().FirstOrDefault();
if (spinnerCtl is not null)
{
    var platform = (OpenHarmonyView)spinnerCtl.Handler!.PlatformView!;
    Console.WriteLine($"[verify] indicator running={platform.IsRunning} needsAnimation={platform.NeedsAnimation}");
}

// Text input plumbing: mapper path, request API (no native host -> no-op), unfocus command.
if (entry is not null)
{
    entry.Text = "typed";
    var entryView = (OpenHarmonyView)entry.Handler!.PlatformView!;
    Console.WriteLine($"[verify] entry text mapped='{entryView.Text}' (virtual='{entry.Text}')");
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestTextInput(true);
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestTextInput(false);
    Console.WriteLine("[verify] RequestTextInput(show/hide) ok (no native host -> no-op)");
    ((IView)entry).Unfocus();
    Console.WriteLine($"[verify] entry unfocus platformFocused={entryView.IsFocused}");

    // W22-14: selection drag inside the entry.
    ((IView)entry).Focus();
    entryView.Text = "abcdefghij";
    Rect ef = entry.Frame;
    float ey = (float)(ef.Y + ef.Height / 2);
    entryView.TextAnchor = -1;
    host.HandleTouch(true, false, (float)(ef.X + ef.Width - 20), ey);
    host.HandleMove((float)(ef.X + 20), ey);
    host.HandleTouch(false, true, (float)(ef.X + 20), ey);
    entryView.TextAnchor = -1;
    Console.WriteLine($"[verify] selection drag cursor={entryView.CursorPosition} length={entryView.SelectionLength} virtual=({entry.CursorPosition},{entry.SelectionLength}) text='{entry.Text}'");
}

// Menus: the current page's MenuBarItems are published as a flat host table (begin/item/commit)
// and a shell tap (host.notifyMenuAction -> internal OnMenuAction) activates the source item
// through IMenuItemController. MenuFlyoutSubItems are flattened and MenuFlyoutSeparators are
// skipped; an item is enabled only when its bar is enabled too.
int menuClicks = 0;
int menuCommands = 0;
int menuDisabledClicks = 0;
var menuPage = new ContentPage { Title = "Menu page", Content = new Label { Text = "menu page" } };
var menuFileBar = new MenuBarItem { Text = "File" };
var menuNew = new MenuFlyoutItem { Text = "New", Command = new Command(() => menuCommands++) };
var menuOpen = new MenuFlyoutItem { Text = "Open" };
menuOpen.Clicked += (_, _) => menuClicks++;
menuFileBar.Add(menuNew);
menuFileBar.Add(new MenuFlyoutSeparator());
menuFileBar.Add(menuOpen);
var menuExport = new MenuFlyoutSubItem { Text = "Export" };
menuExport.Add(new MenuFlyoutItem { Text = "PDF" });
menuExport.Add(new MenuFlyoutItem { Text = "PNG", IsEnabled = false });
menuFileBar.Add(menuExport);
menuPage.MenuBarItems.Add(menuFileBar);
var menuEditBar = new MenuBarItem { Text = "Edit", IsEnabled = false };
var menuUndo = new MenuFlyoutItem { Text = "Undo" };
menuUndo.Clicked += (_, _) => menuDisabledClicks++;
menuEditBar.Add(menuUndo);
menuPage.MenuBarItems.Add(menuEditBar);

bool menuPublished = OpenHarmonyMenus.Refresh(menuPage);
Console.WriteLine($"[verify] menus table count={OpenHarmonyMenus.Items.Count} order=[{string.Join("|", OpenHarmonyMenus.Items.Select(m => $"{m.Index}:{m.Text}"))}] nativePublished={menuPublished} (no host library off-device)");
Console.WriteLine($"[verify] menus enabled=[{string.Join(",", OpenHarmonyMenus.Items.Select(m => m.IsEnabled ? "on" : "off"))}] depth=[{string.Join(",", OpenHarmonyMenus.Items.Select(m => m.Depth))}]");
Console.WriteLine($"[verify] menus publish intent wouldPublish={OpenHarmonyMenus.WouldPublish} lastPublished={OpenHarmonyMenus.LastPublishedCount} available={OpenHarmonyMenus.IsAvailable} (no host library off-device)");
bool menuActivated = OpenHarmonyMenus.OnMenuAction(0);
bool menuCommandActivated = OpenHarmonyMenus.OnMenuAction(1);
bool menuDisabledActivated = OpenHarmonyMenus.OnMenuAction(4);
Console.WriteLine($"[verify] menus activate click={menuActivated}/{menuClicks} command={menuCommandActivated}/{menuCommands} disabledBlocked={!menuDisabledActivated && menuDisabledClicks == 0}");

// An unchanged table is not republished; a different page replaces it (page-change sync).
int menuSkips = OpenHarmonyMenus.RefreshesSkipped;
bool menuRepublished = OpenHarmonyMenus.Refresh(menuPage);
var menuSecondPage = new ContentPage { Title = "Second", Content = new Label { Text = "second" } };
var menuViewBar = new MenuBarItem { Text = "View" };
var menuZoom = new MenuFlyoutItem { Text = "Zoom" };
menuZoom.Clicked += (_, _) => menuClicks++;
menuViewBar.Add(menuZoom);
menuSecondPage.MenuBarItems.Add(menuViewBar);
OpenHarmonyMenus.Refresh(menuSecondPage);
bool menuTableReplaced = OpenHarmonyMenus.Items.Count == 1 && OpenHarmonyMenus.Items[0].Text == "Zoom";
Console.WriteLine($"[verify] menus unchanged skip={!menuRepublished && OpenHarmonyMenus.RefreshesSkipped == menuSkips + 1} pageChangeReplaced={menuTableReplaced} count={OpenHarmonyMenus.Items.Count} text='{OpenHarmonyMenus.Items.FirstOrDefault()?.Text}'");

// Automatic page-change sync: a menu added to the host window's current page is picked up by
// the next platform redraw (the event navigation handlers raise on push/pop), no explicit call.
if (navRoot.CurrentPage is ContentPage livePage)
{
    var liveBar = new MenuBarItem { Text = "Live" };
    liveBar.Add(new MenuFlyoutItem { Text = "Live action" });
    livePage.MenuBarItems.Add(liveBar);
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestRedraw();
    Console.WriteLine($"[verify] menus auto sync on redraw={OpenHarmonyMenus.Items.Any(m => m.Text == "Live action")} count={OpenHarmonyMenus.Items.Count}");
}

// WebView JavaScript bridge (host ohos_host_web_eval/notifyWebEvalResult + shell
// registerWebEvalSink/notifyJsMessage): the managed handler must complete
// WebView.EvaluateJavaScriptAsync without throwing when no host library is present, and the
// native message callback (OnJsMessageNative -> HandleJsMessage) must raise JsMessage with the
// dotnetHost.postMessage payload.
var webProbe = new Microsoft.Maui.Controls.WebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(webProbe);
string? webEval = null;
bool webEvalThrew = false;
try
{
    webEval = await webProbe.EvaluateJavaScriptAsync("1 + 1");
}
catch (Exception ex)
{
    webEvalThrew = true;
    Console.WriteLine($"[verify] webview eval threw {ex.GetType().Name}: {ex.Message}");
}
bool webEvalOk = !webEvalThrew && webEval is null or "";
Console.WriteLine($"[verify] webview handler={webProbe.Handler?.GetType().Name ?? "null"} evaluateAsync completes={webEvalOk} result={(webEval is null ? "<null>" : $"'{webEval}'")} (no host library)");
if (!webEvalOk || webProbe.Handler is not OpenHarmonyWebViewHandler)
{
    throw new InvalidOperationException("WebView.EvaluateJavaScriptAsync did not degrade to null/empty off-device");
}

string? jsMessage = null;
void OnJsMessageProbe(string payload) => jsMessage = payload;
OpenHarmonyWebViewHandler.JsMessage += OnJsMessageProbe;
try
{
    // This is exactly what the native notifyJsMessage callback invokes (OnJsMessageNative).
    OpenHarmonyWebViewHandler.HandleJsMessage("{\"hello\":\"bridge\"}");
}
finally
{
    OpenHarmonyWebViewHandler.JsMessage -= OnJsMessageProbe;
}
bool jsMessageOk = jsMessage == "{\"hello\":\"bridge\"}";
Console.WriteLine($"[verify] webview JsMessage raised={jsMessageOk} payload='{jsMessage}'");
if (!jsMessageOk)
{
    throw new InvalidOperationException("the WebView JsMessage event did not carry the payload");
}

// HybridWebView: the MAUI contracts (EvaluateJavaScriptAsync/SendRawMessage/RawMessageReceived,
// plus InvokeJavaScriptAsync over the same message protocol) ride the same shell channel. The
// handler is registered in SliceHandlers, completes requests off-device instead of hanging, and
// inbound __RawMessage payloads (and plain dotnetHost payloads) reach RawMessageReceived.
bool hybridRegistered = MauiOpenHarmonyExtensions.SliceHandlers.TryGetValue(typeof(IHybridWebView), out Type? hybridType) &&
                        hybridType == typeof(OpenHarmonyHybridWebViewHandler);
var hybridProbe = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(hybridProbe);
string? hybridEval = null;
bool hybridEvalThrew = false;
try
{
    hybridEval = await hybridProbe.EvaluateJavaScriptAsync("1 + 1");
}
catch (Exception ex)
{
    hybridEvalThrew = true;
    Console.WriteLine($"[verify] hybrid eval threw {ex.GetType().Name}: {ex.Message}");
}
bool hybridEvalOk = !hybridEvalThrew && hybridEval is null or "";
Console.WriteLine($"[verify] hybrid handler={hybridProbe.Handler?.GetType().Name ?? "null"} registered={hybridRegistered} evaluateAsync completes={hybridEvalOk} result={(hybridEval is null ? "<null>" : $"'{hybridEval}'")} (no host library; asset registration is a no-op off-device)");
if (!hybridRegistered || hybridProbe.Handler is not OpenHarmonyHybridWebViewHandler || !hybridEvalOk)
{
    throw new InvalidOperationException("the HybridWebView handler assertion failed");
}

string? hybridRaw = null;
hybridProbe.RawMessageReceived += (_, e) => hybridRaw = e.Message;
bool hybridSendThrew = false;
try
{
    hybridProbe.SendRawMessage("raw-from-dotnet");
}
catch (Exception ex)
{
    hybridSendThrew = true;
    Console.WriteLine($"[verify] hybrid send threw {ex.GetType().Name}: {ex.Message}");
}
// B2/B3: the shell prepends "__OHORIGIN|<document url>|<document id>\n" to every payload; the
// handler only accepts messages whose origin is the hybrid page origin and whose document id is
// its own registration id (the id it sent to the shell and the shell stamped into the page).
var hybridProbeHandler = (OpenHarmonyHybridWebViewHandler)hybridProbe.Handler!;
string hybridEnvelope = "__OHORIGIN|" + OpenHarmonyHybridWebViewHandler.HybridAppOrigin + "|" +
    hybridProbeHandler.PageDocumentId + "\n";
OpenHarmonyHybridWebViewHandler.OnJsMessage(hybridEnvelope + "__RawMessage|" + Uri.EscapeDataString("hello <hybrid>"));
string rawPrefixed = hybridRaw ?? "<null>";
hybridRaw = null;
OpenHarmonyHybridWebViewHandler.OnJsMessage(hybridEnvelope + "plain payload");
string rawPlain = hybridRaw ?? "<null>";
// Rejection cases keep the channel closed (no dispatch to any handler): a foreign origin, a
// foreign document id and a payload without the envelope.
hybridRaw = null;
OpenHarmonyHybridWebViewHandler.OnJsMessage("__OHORIGIN|https://evil.invalid/|" + hybridProbeHandler.PageDocumentId +
    "\n__RawMessage|" + Uri.EscapeDataString("evil"));
string rawEvilOrigin = hybridRaw ?? "<null>";
hybridRaw = null;
OpenHarmonyHybridWebViewHandler.OnJsMessage("__OHORIGIN|" + OpenHarmonyHybridWebViewHandler.HybridAppOrigin +
    "|00000000000000000000000000000000\nplain");
string rawForeignId = hybridRaw ?? "<null>";
hybridRaw = null;
OpenHarmonyHybridWebViewHandler.OnJsMessage("plain payload");
string rawMissingEnvelope = hybridRaw ?? "<null>";
bool hybridRawOk = !hybridSendThrew && rawPrefixed == "hello <hybrid>" && rawPlain == "plain payload" &&
    rawEvilOrigin == "<null>" && rawForeignId == "<null>" && rawMissingEnvelope == "<null>";
Console.WriteLine($"[verify] hybrid SendRawMessage degrades={!hybridSendThrew} rawMessage prefixed='{rawPrefixed}' plain='{rawPlain}' rejected(origin/id/envelope)={rawEvilOrigin == "<null>" && rawForeignId == "<null>" && rawMissingEnvelope == "<null>"}");
if (!hybridRawOk)
{
    throw new InvalidOperationException("the HybridWebView raw message assertion failed");
}

// InvokeJavaScriptAsync rides the same protocol (window.HybridWebView.__InvokeJavaScript ->
// __InvokeJavaScriptCompleted). Without a host library the kickoff cannot reach a page, so the
// contract must complete instead of leaving the caller waiting for the timeout.
bool hybridInvokeOk = false;
bool hybridInvokeThrew = false;
try
{
    await hybridProbe.InvokeJavaScriptAsync("verifyNoop");
    hybridInvokeOk = true;
}
catch (Exception ex)
{
    hybridInvokeThrew = true;
    Console.WriteLine($"[verify] hybrid invoke threw {ex.GetType().Name}: {ex.Message}");
}
Console.WriteLine($"[verify] hybrid InvokeJavaScriptAsync completes={hybridInvokeOk} (no host library -> null, no hang)");
if (!hybridInvokeOk || hybridInvokeThrew)
{
    throw new InvalidOperationException("the HybridWebView InvokeJavaScriptAsync path did not complete off-device");
}

// Hybrid asset serving: the shell serves the app package (https://0.0.0.1/ -> <base>/<root>)
// and the framework bootstrap script (<base>/_framework/hybridwebview.js) through the ArkWeb
// component's request interception; the handler extracts that script out of the Microsoft.Maui
// assembly, so the resource name it uses is pinned here.
bool hybridScriptEmbedded;
using (Stream? hybridScript = typeof(Microsoft.Maui.Handlers.HybridWebViewHandler).Assembly
           .GetManifestResourceStream(OpenHarmonyHybridWebViewHandler.HybridWebViewScriptPath))
{
    hybridScriptEmbedded = hybridScript is not null;
}
Console.WriteLine($"[verify] hybrid bootstrap resource '{OpenHarmonyHybridWebViewHandler.HybridWebViewScriptPath}' embedded={hybridScriptEmbedded} origin={OpenHarmonyHybridWebViewHandler.HybridAppOrigin}");
if (!hybridScriptEmbedded)
{
    throw new InvalidOperationException("the HybridWebView bootstrap script resource was not found");
}

// JS -> .NET invocation (__hwvInvokeDotNet): the shell holds the intercepted fetch open with
// setResponseIsReady(false), forwards method + JSON parameter array through
// host.notifyHybridInvoke, and completes the response with the DotNetInvokeResult payload the
// managed handler produces. Off-device the native export is absent, so the payload is
// observed through HybridInvokeResultSent (the same payload a device sends through
// ohos_host_hwv_invoke_result). Every branch must answer - the page's fetch must never hang.
var invokeResults = new Dictionary<int, string>();
void OnHybridInvokeResult(int requestId, string payload) => invokeResults[requestId] = payload;
OpenHarmonyHybridWebViewHandler.HybridInvokeResultSent += OnHybridInvokeResult;
hybridProbe.SetInvokeJavaScriptTarget(new VerifyHybridInvokeTarget());

int invokeEchoId = 91001;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeEchoId, "Echo", "[\"\\\"hi\\\"\"]");
bool invokeEchoOk = invokeResults.TryGetValue(invokeEchoId, out string? echoPayload)
    && PayloadBool(echoPayload, "IsError") == false
    && PayloadBool(echoPayload, "IsJson") == true
    && PayloadString(echoPayload, "Result") == "\"echo:hi\"";
Console.WriteLine($"[verify] hybrid InvokeDotNet round trip method=Echo result={PayloadString(invokeResults.GetValueOrDefault(invokeEchoId), "Result")} payload={invokeResults.GetValueOrDefault(invokeEchoId)}");
if (!invokeEchoOk)
{
    throw new InvalidOperationException("the HybridWebView __hwvInvokeDotNet round trip assertion failed");
}

int invokeAddId = 91002;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeAddId, "Add", "[\"20\",\"22\"]");
bool invokeAddOk = invokeResults.TryGetValue(invokeAddId, out string? addPayload)
    && PayloadBool(addPayload, "IsError") == false
    && PayloadString(addPayload, "Result") == "42";
Console.WriteLine($"[verify] hybrid InvokeDotNet typed result method=Add result={PayloadString(invokeResults.GetValueOrDefault(invokeAddId), "Result")}");
if (!invokeAddOk)
{
    throw new InvalidOperationException("the HybridWebView typed __hwvInvokeDotNet result assertion failed");
}

int invokeMissingId = 91003;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeMissingId, "NoSuchMethod", "[]");
bool invokeMissingOk = invokeResults.TryGetValue(invokeMissingId, out string? missingPayload)
    && PayloadBool(missingPayload, "IsError") == true
    && !string.IsNullOrEmpty(PayloadString(missingPayload, "ErrorMessage"));
Console.WriteLine($"[verify] hybrid InvokeDotNet missing method degrades to an error payload message='{PayloadString(invokeResults.GetValueOrDefault(invokeMissingId), "ErrorMessage")}'");
if (!invokeMissingOk)
{
    throw new InvalidOperationException("the HybridWebView missing-method error payload assertion failed");
}

int invokeBadArgsId = 91004;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeBadArgsId, "Echo", "not-json");
bool invokeBadArgsOk = invokeResults.TryGetValue(invokeBadArgsId, out string? badArgsPayload)
    && PayloadBool(badArgsPayload, "IsError") == true;
Console.WriteLine($"[verify] hybrid InvokeDotNet bad parameter JSON degrades to an error payload message='{PayloadString(invokeResults.GetValueOrDefault(invokeBadArgsId), "ErrorMessage")}'");
if (!invokeBadArgsOk)
{
    throw new InvalidOperationException("the HybridWebView bad-parameter error payload assertion failed");
}

// Honest degradation: a page without an InvokeJavaScriptTarget and a disconnected shell both
// answer an error payload instead of leaving the intercepted fetch open.
var hybridNoTarget = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(hybridNoTarget);
int invokeNoTargetId = 91005;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeNoTargetId, "Echo", "[]");
bool invokeNoTargetOk = invokeResults.TryGetValue(invokeNoTargetId, out string? noTargetPayload)
    && PayloadBool(noTargetPayload, "IsError") == true
    && PayloadString(noTargetPayload, "ErrorMessage")?.Contains("invoker", StringComparison.OrdinalIgnoreCase) == true;
Console.WriteLine($"[verify] hybrid InvokeDotNet without an InvokeJavaScriptTarget degrades message='{PayloadString(invokeResults.GetValueOrDefault(invokeNoTargetId), "ErrorMessage")}'");
if (!invokeNoTargetOk)
{
    throw new InvalidOperationException("the HybridWebView no-invoker error payload assertion failed");
}

hybridNoTarget.Handler?.DisconnectHandler();
hybridNoTarget.Handler = null;
int invokeNoPageId = 91006;
await OpenHarmonyHybridWebViewHandler.OnHybridInvokeAsync(invokeNoPageId, "Echo", "[]");
bool invokeNoPageOk = invokeResults.TryGetValue(invokeNoPageId, out string? noPagePayload)
    && PayloadBool(noPagePayload, "IsError") == true
    && !string.IsNullOrEmpty(PayloadString(noPagePayload, "ErrorMessage"));
Console.WriteLine($"[verify] hybrid InvokeDotNet without a registered page degrades message='{PayloadString(invokeResults.GetValueOrDefault(invokeNoPageId), "ErrorMessage")}'");
if (!invokeNoPageOk)
{
    throw new InvalidOperationException("the HybridWebView no-page error payload assertion failed");
}

bool invokeBridgeDegraded = !OpenHarmonyHybridWebViewHandler.IsInvokeBridgeAvailable && invokeResults.Count == 6;
Console.WriteLine($"[verify] hybrid invoke bridge hostLibraryPresent={OpenHarmonyHybridWebViewHandler.IsInvokeBridgeAvailable} payloads={invokeResults.Count} allCompleted={invokeBridgeDegraded}");
if (!invokeBridgeDegraded)
{
    throw new InvalidOperationException("the HybridWebView invoke bridge degradation assertion failed");
}
OpenHarmonyHybridWebViewHandler.HybridInvokeResultSent -= OnHybridInvokeResult;

// Late app context: the shell can publish AppDir (and with it the payload directory) after a
// HybridWebView connected, so the registration is not dropped: it is remembered as pending and
// retried from the bridge's Initialized/SurfaceChanged signals (late subscribers get the current
// context/surface replayed) and from the first arrange, and each pending root lands exactly
// once. The drill drives that seam directly: OpenHarmonyBridge keeps the context in the private
// s_context field and the Initialized/SurfaceChanged subscribers in private backing delegates,
// so a late context publish and every signal replay are reproduced without a device.
FieldInfo bridgeContextField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_context", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_context was not found; the late-app-context drill needs the bridge seam");
FieldInfo bridgeInitializedField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_initializedHandlers", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_initializedHandlers was not found; the drill replays Initialized like a late context publish");
FieldInfo bridgeSurfaceField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_surfaceHandlers", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_surfaceHandlers was not found; the drill replays SurfaceChanged like a late surface publish");
Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext? savedBridgeContext =
    (Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext?)bridgeContextField.GetValue(null);
void SetBridgeContext(Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext? context)
    => bridgeContextField.SetValue(null, context);
void ReplayInitialized(Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext context)
    => ((Action<Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext>?)bridgeInitializedField.GetValue(null))?.Invoke(context);
void ReplaySurface(Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo surface)
    => ((Action<Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo>?)bridgeSurfaceField.GetValue(null))?.Invoke(surface);
var lateSurface = new Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo(
    IntPtr.Zero, 1080, 1920, Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceState.Changed);

string lateHybridDir = Path.Combine(Path.GetTempPath(), "verify-hybrid-late");
var lateHybridContext = new Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext { AppDir = lateHybridDir };
SetBridgeContext(null);

// (1) A connect without an AppDir is remembered as pending, not dropped.
var lateHybridOne = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200, HybridRoot = "assets", DefaultFile = "main.html" };
OpenHarmonyHandlerConnector.Connect(lateHybridOne);
var lateHandlerOne = (OpenHarmonyHybridWebViewHandler)lateHybridOne.Handler!;
var lateRegistrationsOne = new List<(string Dir, string Root, string File)>();
lateHandlerOne.HybridAssetsRegistered += (dir, root, file) => lateRegistrationsOne.Add((dir, root, file));
bool lateConnectPending = lateHandlerOne.IsHybridAssetsRegistrationPending &&
    lateHandlerOne.RegisteredHybridAssets is null && lateRegistrationsOne.Count == 0;
Console.WriteLine($"[verify] hybrid late connect without AppDir pending={lateHandlerOne.IsHybridAssetsRegistrationPending} registered={lateHandlerOne.RegisteredHybridAssets ?? "<null>"} dropped={lateRegistrationsOne.Count != 0} assert={lateConnectPending}");
if (!lateConnectPending)
{
    throw new InvalidOperationException("a HybridWebView connected before AppDir was published was not remembered as pending");
}

// (2) The first replay after the context lands registers exactly once with the payload layout.
SetBridgeContext(lateHybridContext);
ReplayInitialized(lateHybridContext);
(bool lateLandedOnce, string lateDirSeen, string lateRootSeen, string lateFileSeen) = lateRegistrationsOne.Count == 1
    ? (true, lateRegistrationsOne[0].Dir, lateRegistrationsOne[0].Root, lateRegistrationsOne[0].File)
    : (false, "<none>", "<none>", "<none>");
bool lateBootstrapExtracted = File.Exists(Path.Combine(lateHybridDir, "_framework", "hybridwebview.js"));
bool lateReplayOk = lateLandedOnce && lateDirSeen == lateHybridDir && lateRootSeen == "assets" &&
    lateFileSeen == "main.html" && lateBootstrapExtracted && !lateHandlerOne.IsHybridAssetsRegistrationPending;
Console.WriteLine($"[verify] hybrid late replay registrations={lateRegistrationsOne.Count} dir='{lateDirSeen}' root='{lateRootSeen}' defaultFile='{lateFileSeen}' bootstrap={lateBootstrapExtracted} pending={lateHandlerOne.IsHybridAssetsRegistrationPending} assert={lateReplayOk}");
if (!lateReplayOk)
{
    throw new InvalidOperationException("the late AppDir replay did not register the pending hybrid root exactly once with the expected payload layout");
}

// (3) Replaying Initialized for the same context does not register the root again.
ReplayInitialized(lateHybridContext);
bool lateInitializedIdempotent = lateRegistrationsOne.Count == 1;
Console.WriteLine($"[verify] hybrid late replay Initialized again registrations={lateRegistrationsOne.Count} assert={lateInitializedIdempotent}");
if (!lateInitializedIdempotent)
{
    throw new InvalidOperationException("replaying the Initialized signal re-registered an already registered hybrid root");
}

// (4) Replaying SurfaceChanged does not register the root again either.
ReplaySurface(lateSurface);
bool lateSurfaceIdempotent = lateRegistrationsOne.Count == 1;
Console.WriteLine($"[verify] hybrid late replay SurfaceChanged registrations={lateRegistrationsOne.Count} assert={lateSurfaceIdempotent}");
if (!lateSurfaceIdempotent)
{
    throw new InvalidOperationException("replaying the SurfaceChanged signal re-registered an already registered hybrid root");
}

// (5) Every signal plus repeated mapper passes stay idempotent.
ReplayInitialized(lateHybridContext);
ReplaySurface(lateSurface);
OpenHarmonyHybridWebViewHandler.MapHybridAssets(lateHandlerOne, lateHybridOne);
OpenHarmonyHybridWebViewHandler.MapHybridAssets(lateHandlerOne, lateHybridOne);
bool lateAllSignalsIdempotent = lateRegistrationsOne.Count == 1;
Console.WriteLine($"[verify] hybrid late replay all signals registrations={lateRegistrationsOne.Count} assert={lateAllSignalsIdempotent}");
if (!lateAllSignalsIdempotent)
{
    throw new InvalidOperationException("replaying every bridge signal re-registered an already registered hybrid root");
}

// (6) A HybridRoot change re-registers once (the shell command carries the new root).
lateHybridOne.HybridRoot = "assets2";
(bool lateRootOnce, string lateRootDirSeen, string lateRootSeenValue, string lateRootFileSeen) = lateRegistrationsOne.Count == 2
    ? (true, lateRegistrationsOne[1].Dir, lateRegistrationsOne[1].Root, lateRegistrationsOne[1].File)
    : (false, "<none>", "<none>", "<none>");
bool lateRootChangeOk = lateRootOnce && lateRootDirSeen == lateHybridDir &&
    lateRootSeenValue == "assets2" && lateRootFileSeen == "main.html";
Console.WriteLine($"[verify] hybrid late HybridRoot change registrations={lateRegistrationsOne.Count} root='{lateRootSeenValue}' assert={lateRootChangeOk}");
if (!lateRootChangeOk)
{
    throw new InvalidOperationException("a HybridRoot change did not re-register the hybrid root exactly once");
}

// (7) The signals remain idempotent after the root change.
ReplayInitialized(lateHybridContext);
ReplaySurface(lateSurface);
bool lateRootChangeIdempotent = lateRegistrationsOne.Count == 2;
Console.WriteLine($"[verify] hybrid late replay after root change registrations={lateRegistrationsOne.Count} assert={lateRootChangeIdempotent}");
if (!lateRootChangeIdempotent)
{
    throw new InvalidOperationException("replaying the bridge signals after a HybridRoot change re-registered the root");
}

// (8) The eager path still registers immediately when the context is already published.
var lateHybridEager = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200, HybridRoot = "eager", DefaultFile = "index.html" };
var lateHandlerEager = new OpenHarmonyHybridWebViewHandler();
var lateRegistrationsEager = new List<(string Dir, string Root, string File)>();
lateHandlerEager.HybridAssetsRegistered += (dir, root, file) => lateRegistrationsEager.Add((dir, root, file));
((IElementHandler)lateHandlerEager).SetMauiContext(OpenHarmonyHandlerConnector.Context);
lateHybridEager.Handler = lateHandlerEager;
bool lateEagerOk = !lateHandlerEager.IsHybridAssetsRegistrationPending && lateRegistrationsEager.Count == 1 &&
    lateRegistrationsEager[0] == (lateHybridDir, "eager", "index.html");
Console.WriteLine($"[verify] hybrid late eager connect pending={lateHandlerEager.IsHybridAssetsRegistrationPending} registrations={lateRegistrationsEager.Count} dir='{(lateRegistrationsEager.Count == 1 ? lateRegistrationsEager[0].Dir : "<none>")}' root='{(lateRegistrationsEager.Count == 1 ? lateRegistrationsEager[0].Root : "<none>")}' assert={lateEagerOk}");
if (!lateEagerOk)
{
    throw new InvalidOperationException("the eager hybrid asset registration path no longer registers immediately");
}

// (9) Two handlers that connected without an AppDir are both remembered.
SetBridgeContext(null);
var lateHybridTwo = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
var lateHybridThree = new Microsoft.Maui.Controls.HybridWebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(lateHybridTwo);
OpenHarmonyHandlerConnector.Connect(lateHybridThree);
var lateHandlerTwo = (OpenHarmonyHybridWebViewHandler)lateHybridTwo.Handler!;
var lateHandlerThree = (OpenHarmonyHybridWebViewHandler)lateHybridThree.Handler!;
var lateRegistrationsTwo = new List<(string Dir, string Root, string File)>();
var lateRegistrationsThree = new List<(string Dir, string Root, string File)>();
lateHandlerTwo.HybridAssetsRegistered += (dir, root, file) => lateRegistrationsTwo.Add((dir, root, file));
lateHandlerThree.HybridAssetsRegistered += (dir, root, file) => lateRegistrationsThree.Add((dir, root, file));
bool lateTwoRemembered = lateHandlerTwo.IsHybridAssetsRegistrationPending && lateHandlerThree.IsHybridAssetsRegistrationPending &&
    lateRegistrationsTwo.Count == 0 && lateRegistrationsThree.Count == 0;
Console.WriteLine($"[verify] hybrid late two pending handlers remembered pending={lateHandlerTwo.IsHybridAssetsRegistrationPending}/{lateHandlerThree.IsHybridAssetsRegistrationPending} registrations={lateRegistrationsTwo.Count}/{lateRegistrationsThree.Count} assert={lateTwoRemembered}");
if (!lateTwoRemembered)
{
    throw new InvalidOperationException("two HybridWebViews connected before AppDir were not both remembered as pending");
}

// (10) When the context lands, each pending handler registers exactly once (one by one).
SetBridgeContext(lateHybridContext);
ReplayInitialized(lateHybridContext);
bool lateTwoLanded = lateRegistrationsTwo.Count == 1 && lateRegistrationsThree.Count == 1 &&
    !lateHandlerTwo.IsHybridAssetsRegistrationPending && !lateHandlerThree.IsHybridAssetsRegistrationPending;
Console.WriteLine($"[verify] hybrid late two pending handlers land registrations={lateRegistrationsTwo.Count}/{lateRegistrationsThree.Count} pending={lateHandlerTwo.IsHybridAssetsRegistrationPending}/{lateHandlerThree.IsHybridAssetsRegistrationPending} assert={lateTwoLanded}");
if (!lateTwoLanded)
{
    throw new InvalidOperationException("the pending hybrid roots did not land one by one when the late AppDir arrived");
}

foreach (Microsoft.Maui.Controls.HybridWebView lateProbe in new[] { lateHybridOne, lateHybridEager, lateHybridTwo, lateHybridThree })
{
    lateProbe.Handler?.DisconnectHandler();
    lateProbe.Handler = null;
}
SetBridgeContext(savedBridgeContext);
try
{
    Directory.Delete(lateHybridDir, true);
}
catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
{
    // The temp payload directory is diagnostic only; leaving it behind must not fail the suite.
}

// ---- B6/B7: navigation allow-list and the bounded web status log ------------------------------
// B6: the shell cancels main-frame loads it did not originate and asks the managed handler for a
// decision over the existing JS-message channel ("__OHNAV|<url>|<id>"). The handler raises
// IWebView.Navigating (the cancel flag blocks the load), approves only the exact (id, url) pair
// back when the app allows it, never fans the envelope out to JsMessage, and suppresses the
// page-begin Navigating for the approved reload (one-shot). B7: the page-finish status line drops
// the query/fragment, flattens control characters, truncates the URL and keeps dotnet-status.txt
// capped (oldest lines dropped). These three checks are the pins the slice change was verified
// with; they run here so CI keeps guarding the flow off-device.

// B7a: the logged URL keeps scheme+host+path, drops query/fragment and control characters, and
// is truncated.
string b7LongUrl = "https://example.com/" + new string('a', 4096) + "?token=SECRET#fragment";
string b7Sanitized = OpenHarmonyWebViewHandler.SanitizeUrlForLog(b7LongUrl);
string b7Flattened = OpenHarmonyWebViewHandler.SanitizeUrlForLog("https://example.com/a\nb\r\tc?x=1");
bool b7SanitizeOk = b7Sanitized.Length == OpenHarmonyWebViewHandler.MaxLoggedUrlLength &&
    b7Sanitized.StartsWith("https://example.com/") && b7Sanitized.EndsWith("...") &&
    !b7Sanitized.Contains('?') && !b7Sanitized.Contains('#') && !b7Sanitized.Contains("SECRET") &&
    b7Flattened == "https://example.com/a b  c";
Console.WriteLine($"[verify] b7 sanitize length={b7Sanitized.Length} query={b7Sanitized.Contains('?')} fragment={b7Sanitized.Contains('#')} flat='{b7Flattened}' assert={b7SanitizeOk}");
if (!b7SanitizeOk)
{
    throw new InvalidOperationException("the logged-URL sanitizer (B7) did not strip/truncate as required");
}

// B7b: 300 finished events through a connected handler write a bounded file whose newest lines
// survive and whose content never carries a query.
string b7StatusDir = Path.Combine(Path.GetTempPath(), "verify-web-status");
Directory.CreateDirectory(b7StatusDir);
SetBridgeContext(new Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext { FilesDir = b7StatusDir });
string b7StatusPath = Path.Combine(b7StatusDir, "dotnet-status.txt");
File.Delete(b7StatusPath);
var webNavProbe = new Microsoft.Maui.Controls.WebView { HeightRequest = 200 };
OpenHarmonyHandlerConnector.Connect(webNavProbe);
for (int i = 0; i < 300; i++)
{
    OpenHarmonyWebViewHandler.OnPageEvent("finished", $"https://example.com/page{i}/{new string('x', 4096)}?token=SECRET{i}#fragment");
}
long b7Length = new FileInfo(b7StatusPath).Length;
string b7Log = File.ReadAllText(b7StatusPath);
bool b7CapOk = b7Length <= 256 * 1024 && b7Log.Contains("https://example.com/page299/") &&
    !b7Log.Contains("/page0/") && !b7Log.Contains("SECRET") && !b7Log.Contains('?') &&
    b7Log.Contains("[maui] web finished: https://example.com/page");
Console.WriteLine($"[verify] b7 status bytes={b7Length} within256KiB={b7Length <= 256 * 1024} newest={b7Log.Contains("page299")} oldestDropped={!b7Log.Contains("/page0/")} noQuery={!b7Log.Contains('?')} assert={b7CapOk}");
if (!b7CapOk)
{
    throw new InvalidOperationException("dotnet-status.txt (B7) exceeded the cap or lost its recent lines");
}

// B6: the managed half of the honored-cancel design. A "__OHNAV|url|id" envelope from the
// shell raises Navigating; a cancellation produces no approval, an allowed URL approves
// exactly (id, url) back, forged/malformed envelopes are inert, and the started event of an
// approved URL does not raise Navigating a second time (one-shot).
var b6Events = new List<(string Url, bool Cancel)>();
bool b6CancelNext = false;
void OnB6Navigating(object? sender, WebNavigatingEventArgs e)
{
    if (e.Url is not null && e.Url.StartsWith("https://example.com/rbb", StringComparison.Ordinal))
    {
        e.Cancel = b6CancelNext;
        b6Events.Add((e.Url, e.Cancel));
    }
}
var b6Approvals = new List<(string Id, string Url)>();
void OnB6Approval(string id, string url) => b6Approvals.Add((id, url));
webNavProbe.Navigating += OnB6Navigating;
OpenHarmonyWebViewHandler.NavigationApprovalSent += OnB6Approval;

OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.com/rbb/allow?q=1|id-allow");
bool b6ApprovalOk = b6Events.Count == 1 &&
    b6Events[0] == ("https://example.com/rbb/allow?q=1", false) &&
    b6Approvals.Count == 1 && b6Approvals[0] == ("id-allow", "https://example.com/rbb/allow?q=1");
b6CancelNext = true;
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.com/rbb/deny|id-deny");
bool b6CancelOk = b6Events.Count == 2 && b6Approvals.Count == 1 && b6Events[1].Cancel;
b6CancelNext = false;
string? b6PagePayload = null;
void OnB6Js(string payload) => b6PagePayload = payload;
OpenHarmonyWebViewHandler.JsMessage += OnB6Js;
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.com/rbb/fanout|id-fanout");
OpenHarmonyWebViewHandler.HandleJsMessage("__OHORIGIN|https://example.com/|doc\n__OHNAV|https://example.com/rbb/forged|id-forged");
OpenHarmonyWebViewHandler.JsMessage -= OnB6Js;
bool b6ChannelOk = b6PagePayload == "__OHORIGIN|https://example.com/|doc\n__OHNAV|https://example.com/rbb/forged|id-forged" &&
    b6Approvals.Count == 2 && b6Approvals[1] == ("id-fanout", "https://example.com/rbb/fanout");
int b6MalformedBefore = b6Approvals.Count;
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV||id");
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|not-a-url|id");
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.com/rbb/ctrl|id\nx");
OpenHarmonyWebViewHandler.HandleJsMessage(string.Empty);
bool b6MalformedOk = b6Approvals.Count == b6MalformedBefore;
int b6EventsBeforeStarted = b6Events.Count;
OpenHarmonyWebViewHandler.OnPageEvent("started", "https://example.com/rbb/fanout");
bool b6NoDuplicate = b6Events.Count == b6EventsBeforeStarted;
OpenHarmonyWebViewHandler.OnPageEvent("started", "https://example.com/rbb/fanout");
bool b6OneShotOk = b6Events.Count == b6EventsBeforeStarted + 1;
webNavProbe.Navigating -= OnB6Navigating;
OpenHarmonyWebViewHandler.NavigationApprovalSent -= OnB6Approval;
Console.WriteLine($"[verify] b6 approval={b6ApprovalOk} cancelBlocked={b6CancelOk} channelScoped={b6ChannelOk} malformedInert={b6MalformedOk} startedSuppressed={b6NoDuplicate} oneShot={b6OneShotOk} approvals={b6Approvals.Count}");
if (!(b6ApprovalOk && b6CancelOk && b6ChannelOk && b6MalformedOk && b6NoDuplicate && b6OneShotOk))
{
    throw new InvalidOperationException("the honored-cancel approval flow (B6) did not behave as specified");
}

webNavProbe.Handler?.DisconnectHandler();
webNavProbe.Handler = null;
SetBridgeContext(savedBridgeContext);
try
{
    Directory.Delete(b7StatusDir, true);
}
catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
{
    // The temp status directory is diagnostic only; leaving it behind must not fail the suite.
}

static bool PayloadBool(string? payload, string name)
    => !string.IsNullOrEmpty(payload) && JsonDocument.Parse(payload).RootElement.GetProperty(name).GetBoolean();

static string? PayloadString(string? payload, string name)
    => string.IsNullOrEmpty(payload) ? null : JsonDocument.Parse(payload).RootElement.GetProperty(name).GetString();

// Gap 5: Contacts/Calendar platform extras over the host/ArkTS kit bridge
// (ohos_host_contacts_query / ohos_host_calendar_list / ohos_host_calendar_add ->
// shell registerContactsSink / registerCalendarSink -> @kit.ContactsKit / @kit.CalendarKit).
// Off-device there is no libopenharmonyhost.so, so both must return empty/false without throwing
// and report IsSupported == false; the wire parsers are proven with the exact delimited payload
// shape the shell sends ("name\tphone" and "title\tstartIso\tendIso" lines).
bool contactsSupportedBefore = OpenHarmonyContacts.IsSupported;
IReadOnlyList<OpenHarmonyContact> contactsFound = Array.Empty<OpenHarmonyContact>();
bool contactsThrew = false;
try
{
    contactsFound = await OpenHarmonyContacts.FindAsync("ver", 5);
}
catch (Exception ex)
{
    contactsThrew = true;
    Console.WriteLine($"[verify] contacts FindAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool contactsDegraded = !contactsThrew && contactsFound.Count == 0 &&
    !contactsSupportedBefore && !OpenHarmonyContacts.IsSupported;
Console.WriteLine($"[verify] contacts FindAsync degraded without throwing={!contactsThrew} count={contactsFound.Count} supported(before={contactsSupportedBefore}, after={OpenHarmonyContacts.IsSupported})");
if (!contactsDegraded)
{
    throw new InvalidOperationException("OpenHarmonyContacts.FindAsync did not degrade off-device");
}

var contactsParsed = OpenHarmonyContacts.Parse("Ada Lovelace\t+15550100\nGrace Hopper\t+15550101\nNo Phone\n");
var contactsEscaped = OpenHarmonyContacts.Parse("Esc\\naped\\tName\t+15550102\n");
var contactsInjected = OpenHarmonyContacts.Parse("A\nFake\t555");
bool contactsParsedOk = contactsParsed.Count == 2 &&
    contactsParsed[0] == new OpenHarmonyContact("Ada Lovelace", "+15550100") &&
    contactsParsed[1] == new OpenHarmonyContact("Grace Hopper", "+15550101") &&
    contactsEscaped.Count == 1 && contactsEscaped[0].Name == "Esc\naped\tName" &&
    contactsInjected.Count == 1 && contactsInjected[0].Name == "A\nFake" &&
    contactsInjected[0].Phone == "555";
Console.WriteLine($"[verify] contacts parser count={contactsParsed.Count} first='{contactsParsed[0].Name}/{contactsParsed[0].Phone}' second='{contactsParsed[1].Name}/{contactsParsed[1].Phone}' escapedDecoded={contactsEscaped[0].Name == "Esc\naped\tName"} injectionGuarded={contactsInjected.Count == 1 && contactsInjected[0].Name == "A\nFake"} assert={contactsParsedOk}");
if (!contactsParsedOk)
{
    throw new InvalidOperationException("the contacts payload parser assertion failed");
}

bool calendarSupportedBefore = OpenHarmonyCalendar.IsSupported;
IReadOnlyList<OpenHarmonyCalendarEvent> upcoming = Array.Empty<OpenHarmonyCalendarEvent>();
bool calendarListThrew = false;
try
{
    upcoming = await OpenHarmonyCalendar.ListUpcomingAsync(7);
}
catch (Exception ex)
{
    calendarListThrew = true;
    Console.WriteLine($"[verify] calendar ListUpcomingAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool calendarDegraded = !calendarListThrew && upcoming.Count == 0 &&
    !calendarSupportedBefore && !OpenHarmonyCalendar.IsSupported;
Console.WriteLine($"[verify] calendar ListUpcomingAsync degraded without throwing={!calendarListThrew} count={upcoming.Count} supported(before={calendarSupportedBefore}, after={OpenHarmonyCalendar.IsSupported})");
if (!calendarDegraded)
{
    throw new InvalidOperationException("OpenHarmonyCalendar.ListUpcomingAsync did not degrade off-device");
}

bool addReturned = true;
bool calendarAddThrew = false;
try
{
    addReturned = await OpenHarmonyCalendar.AddEventAsync(
        "Verify event", "2026-09-19T09:00:00.000Z", "2026-09-19T10:00:00.000Z");
}
catch (Exception ex)
{
    calendarAddThrew = true;
    Console.WriteLine($"[verify] calendar AddEventAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool calendarAddDegraded = !calendarAddThrew && !addReturned;
Console.WriteLine($"[verify] calendar AddEventAsync degraded without throwing={!calendarAddThrew} returned={addReturned}");
if (!calendarAddDegraded)
{
    throw new InvalidOperationException("OpenHarmonyCalendar.AddEventAsync did not degrade off-device");
}

var eventsParsed = OpenHarmonyCalendar.Parse(
    "Team sync\t2026-09-19T09:00:00.000Z\t2026-09-19T10:00:00.000Z\n" +
    "Local standup\t2026-09-20T09:30:00+08:00\t2026-09-20T09:45:00+08:00\n" +
    "broken line\n" +
    "Bad dates\tnot-a-date\t2026-09-20T10:00:00.000Z\n");
bool calendarParsedOk = eventsParsed.Count == 2 &&
    eventsParsed[0].Title == "Team sync" &&
    eventsParsed[0].Start == DateTimeOffset.Parse("2026-09-19T09:00:00.000Z", System.Globalization.CultureInfo.InvariantCulture) &&
    eventsParsed[0].End == DateTimeOffset.Parse("2026-09-19T10:00:00.000Z", System.Globalization.CultureInfo.InvariantCulture) &&
    eventsParsed[1].Title == "Local standup" &&
    eventsParsed[1].Start == DateTimeOffset.Parse("2026-09-20T09:30:00+08:00", System.Globalization.CultureInfo.InvariantCulture);
Console.WriteLine($"[verify] calendar parser count={eventsParsed.Count} first='{eventsParsed[0].Title}/{eventsParsed[0].Start:O}' splitLinesDropped={eventsParsed.Count == 2} assert={calendarParsedOk}");
if (!calendarParsedOk)
{
    throw new InvalidOperationException("the calendar payload parser assertion failed");
}

// Gap 6: Bluetooth/Printing platform extras over the same host/ArkTS kit bridge
// (ohos_host_bluetooth_query -> shell registerBluetoothSink -> @kit.ConnectivityKit
// access/connection; ohos_host_print_file -> shell registerPrintSink -> @ohos.print).
// Off-device there is no libopenharmonyhost.so, so every call must return false/empty without
// throwing and report IsSupported == false; the paired-device/state parsers and the text->PDF
// renderer are exercised with simulated payloads.
bool bluetoothSupportedBefore = OpenHarmonyBluetooth.IsSupported;
bool bluetoothEnabled = true;
bool bluetoothEnabledThrew = false;
try
{
    bluetoothEnabled = await OpenHarmonyBluetooth.IsEnabledAsync();
}
catch (Exception ex)
{
    bluetoothEnabledThrew = true;
    Console.WriteLine($"[verify] bluetooth IsEnabledAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool bluetoothEnabledDegraded = !bluetoothEnabledThrew && !bluetoothEnabled &&
    !bluetoothSupportedBefore && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth IsEnabledAsync degraded without throwing={!bluetoothEnabledThrew} enabled={bluetoothEnabled} supported(before={bluetoothSupportedBefore}, after={OpenHarmonyBluetooth.IsSupported})");
if (!bluetoothEnabledDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.IsEnabledAsync did not degrade off-device");
}

IReadOnlyList<OpenHarmonyBluetoothDevice> pairedDevices = Array.Empty<OpenHarmonyBluetoothDevice>();
bool pairedThrew = false;
try
{
    pairedDevices = await OpenHarmonyBluetooth.GetPairedDevicesAsync();
}
catch (Exception ex)
{
    pairedThrew = true;
    Console.WriteLine($"[verify] bluetooth GetPairedDevicesAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool pairedDegraded = !pairedThrew && pairedDevices.Count == 0 && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth GetPairedDevicesAsync degraded without throwing={!pairedThrew} count={pairedDevices.Count} supported={OpenHarmonyBluetooth.IsSupported}");
if (!pairedDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.GetPairedDevicesAsync did not degrade off-device");
}

bool discoveryStarted = true;
bool discoveryStopped = true;
bool discoveryThrew = false;
try
{
    discoveryStarted = await OpenHarmonyBluetooth.StartDiscoveryAsync();
    discoveryStopped = await OpenHarmonyBluetooth.StopDiscoveryAsync();
}
catch (Exception ex)
{
    discoveryThrew = true;
    Console.WriteLine($"[verify] bluetooth discovery threw {ex.GetType().Name}: {ex.Message}");
}
bool discoveryDegraded = !discoveryThrew && !discoveryStarted && !discoveryStopped;
Console.WriteLine($"[verify] bluetooth discovery degraded without throwing={!discoveryThrew} started={discoveryStarted} stopped={discoveryStopped}");
if (!discoveryDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth discovery did not degrade off-device");
}

var pairedParsed = OpenHarmonyBluetooth.ParsePairedDevices(
    "QuietComfort\tAA:BB:CC:DD:EE:01\n\tAA:BB:CC:DD:EE:02\nNoAddressOnly\n");
bool pairedParsedOk = pairedParsed.Count == 2 &&
    pairedParsed[0] == new OpenHarmonyBluetoothDevice("QuietComfort", "AA:BB:CC:DD:EE:01") &&
    pairedParsed[1] == new OpenHarmonyBluetoothDevice(string.Empty, "AA:BB:CC:DD:EE:02") &&
    OpenHarmonyBluetooth.ParsePairedDevices("No\\tTab\tAA:BB\n")[0] == new OpenHarmonyBluetoothDevice("No\tTab", "AA:BB");
Console.WriteLine($"[verify] bluetooth paired parser count={pairedParsed.Count} first='{pairedParsed[0].Name}/{pairedParsed[0].Address}' nameless='{pairedParsed[1].Address}' escapedDecoded={OpenHarmonyBluetooth.ParsePairedDevices("No\\tTab\tAA:BB\n")[0].Name == "No\tTab"} assert={pairedParsedOk}");
if (!pairedParsedOk)
{
    throw new InvalidOperationException("the bluetooth paired-device payload parser assertion failed");
}

bool stateOn = OpenHarmonyBluetooth.ParseAdapterState("2");
bool stateOff = OpenHarmonyBluetooth.ParseAdapterState("0");
bool stateTurningOn = OpenHarmonyBluetooth.ParseAdapterState("1");
bool stateGarbage = OpenHarmonyBluetooth.ParseAdapterState("nope") ||
    OpenHarmonyBluetooth.ParseAdapterState(null);
bool stateParsedOk = stateOn && !stateOff && !stateTurningOn && !stateGarbage;
Console.WriteLine($"[verify] bluetooth state parser on={stateOn} off={stateOff} turningOn={stateTurningOn} garbage={stateGarbage} assert={stateParsedOk}");
if (!stateParsedOk)
{
    throw new InvalidOperationException("the bluetooth adapter-state parser assertion failed");
}

// Discovery devices (Gap 6 follow-up): op 4 returns the bluetoothDeviceFind table, each device
// also arrives as a pushed DeviceFound event. Off-device both must degrade without throwing.
IReadOnlyList<OpenHarmonyBluetoothDevice> discoveredDevices = Array.Empty<OpenHarmonyBluetoothDevice>();
bool discoveredThrew = false;
try
{
    discoveredDevices = await OpenHarmonyBluetooth.GetDiscoveredDevicesAsync();
}
catch (Exception ex)
{
    discoveredThrew = true;
    Console.WriteLine($"[verify] bluetooth GetDiscoveredDevicesAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool discoveredDegraded = !discoveredThrew && discoveredDevices.Count == 0 && !OpenHarmonyBluetooth.IsSupported;
Console.WriteLine($"[verify] bluetooth GetDiscoveredDevicesAsync degraded without throwing={!discoveredThrew} count={discoveredDevices.Count} supported={OpenHarmonyBluetooth.IsSupported}");
if (!discoveredDegraded)
{
    throw new InvalidOperationException("OpenHarmonyBluetooth.GetDiscoveredDevicesAsync did not degrade off-device");
}

var discoveredParsed = OpenHarmonyBluetooth.ParseDevices(
    "QuietComfort\tAA:BB:CC:DD:EE:01\n\tAA:BB:CC:DD:EE:02\nNoAddressOnly\n");
bool parseDevicesOk = discoveredParsed.Count == 2 &&
    discoveredParsed[0] == new OpenHarmonyBluetoothDevice("QuietComfort", "AA:BB:CC:DD:EE:01") &&
    discoveredParsed[1] == new OpenHarmonyBluetoothDevice(string.Empty, "AA:BB:CC:DD:EE:02") &&
    OpenHarmonyBluetooth.ParsePairedDevices(null).Count == 0 &&
    OpenHarmonyBluetooth.ParsePairedDevices("X\tY").Count == 1 &&
    OpenHarmonyBluetooth.ParsePairedDevices("X\tY")[0] == new OpenHarmonyBluetoothDevice("X", "Y");
Console.WriteLine($"[verify] bluetooth device parser count={discoveredParsed.Count} first='{discoveredParsed[0].Name}/{discoveredParsed[0].Address}' nameless='{discoveredParsed[1].Address}' pairedDelegates=True assert={parseDevicesOk}");
if (!parseDevicesOk)
{
    throw new InvalidOperationException("the bluetooth device payload parser assertion failed");
}

string? foundName = null;
string? foundAddress = null;
int foundCount = 0;
EventHandler<OpenHarmonyBluetoothDevice> onDeviceFound = (_, device) =>
{
    foundName = device.Name;
    foundAddress = device.Address;
    foundCount++;
};
OpenHarmonyBluetooth.DeviceFound += onDeviceFound;
bool foundThrew = false;
try
{
    OpenHarmonyBluetooth.OnDeviceFoundPayload("Headset\t11:22:33:44:55:66");
    OpenHarmonyBluetooth.OnDeviceFoundPayload(null);
    OpenHarmonyBluetooth.OnDeviceFoundPayload("malformed-without-tab-is-still-a-device");
    OpenHarmonyBluetooth.OnDeviceFoundPayload(string.Empty);
}
catch (Exception ex)
{
    foundThrew = true;
    Console.WriteLine($"[verify] bluetooth DeviceFound payload threw {ex.GetType().Name}: {ex.Message}");
}
OpenHarmonyBluetooth.DeviceFound -= onDeviceFound;
// The tabless record is not a valid "name\taddress" pair, so only the complete one raises.
bool deviceFoundOk = !foundThrew && foundCount == 1 && foundName == "Headset" &&
    foundAddress == "11:22:33:44:55:66";
Console.WriteLine($"[verify] bluetooth DeviceFound event count={foundCount} last='{foundName}/{foundAddress}' tablessDropped={foundCount == 1} noThrow={!foundThrew} assert={deviceFoundOk}");
if (!deviceFoundOk)
{
    throw new InvalidOperationException("the bluetooth DeviceFound event assertion failed");
}

bool printingSupportedBefore = OpenHarmonyPrinting.IsSupported;
bool printMissingReturned = true;
bool printMissingThrew = false;
try
{
    printMissingReturned = await OpenHarmonyPrinting.PrintFileAsync(
        Path.Combine(FileSystem.CacheDirectory, "verify-missing-print-file.pdf"));
}
catch (Exception ex)
{
    printMissingThrew = true;
    Console.WriteLine($"[verify] printing PrintFileAsync threw {ex.GetType().Name}: {ex.Message}");
}
bool printMissingDegraded = !printMissingThrew && !printMissingReturned &&
    !printingSupportedBefore && !OpenHarmonyPrinting.IsSupported;
Console.WriteLine($"[verify] printing PrintFileAsync missing-file degraded without throwing={!printMissingThrew} returned={printMissingReturned} supported(before={printingSupportedBefore}, after={OpenHarmonyPrinting.IsSupported})");
if (!printMissingDegraded)
{
    throw new InvalidOperationException("OpenHarmonyPrinting.PrintFileAsync did not degrade off-device");
}

bool printTextReturned = true;
bool printTextThrew = false;
try
{
    printTextReturned = await OpenHarmonyPrinting.PrintTextAsync("verify text", "Hello printing\nSecond line");
}
catch (Exception ex)
{
    printTextThrew = true;
    Console.WriteLine($"[verify] printing PrintTextAsync threw {ex.GetType().Name}: {ex.Message}");
}
string textPdfPath = Path.Combine(FileSystem.CacheDirectory, "verify_text.pdf");
bool textPdfWritten = File.Exists(textPdfPath) &&
    System.Text.Encoding.ASCII.GetString(File.ReadAllBytes(textPdfPath), 0, 8) == "%PDF-1.4";
bool printTextDegraded = !printTextThrew && !printTextReturned && !OpenHarmonyPrinting.IsSupported;
Console.WriteLine($"[verify] printing PrintTextAsync degraded without throwing={!printTextThrew} returned={printTextReturned} wrotePdf={textPdfWritten} supported={OpenHarmonyPrinting.IsSupported}");
if (!printTextDegraded || !textPdfWritten)
{
    throw new InvalidOperationException("OpenHarmonyPrinting.PrintTextAsync did not degrade off-device");
}
File.Delete(textPdfPath);

byte[] textPdf = OpenHarmonyPrinting.BuildTextPdf(
    "Hello print\nLine two\n\nEscapes (paren) and \\ slash\nCafe\u00e9");
string pdfAscii = System.Text.Encoding.ASCII.GetString(textPdf);
int startxrefIndex = pdfAscii.LastIndexOf("startxref\n", StringComparison.Ordinal);
int pdfXrefOffset = -1;
if (startxrefIndex >= 0)
{
    int valueStart = startxrefIndex + "startxref\n".Length;
    int valueEnd = pdfAscii.IndexOf('\n', valueStart);
    if (valueEnd > valueStart)
    {
        int.TryParse(pdfAscii.AsSpan(valueStart, valueEnd - valueStart), out pdfXrefOffset);
    }
}
// Skip the "xref" line, the "0 <count>" line and the free entry to reach object 1's entry.
int firstXrefEntry = pdfAscii.IndexOf('\n', pdfXrefOffset) + 1;
firstXrefEntry = pdfAscii.IndexOf('\n', firstXrefEntry) + 1;
firstXrefEntry = pdfAscii.IndexOf('\n', firstXrefEntry) + 1;
int firstObjectOffset = -1;
if (firstXrefEntry > 0)
{
    int.TryParse(pdfAscii.AsSpan(firstXrefEntry, 10), out firstObjectOffset);
}
// Every xref entry (1..Size-1) must point at its "<n> 0 obj" header.
int pdfSizeStart = pdfAscii.IndexOf("/Size ", StringComparison.Ordinal) + "/Size ".Length;
int pdfSizeEnd = pdfAscii.IndexOf(' ', pdfSizeStart);
int pdfObjectCount = 0;
if (pdfSizeStart > 0 && pdfSizeEnd > pdfSizeStart)
{
    int.TryParse(pdfAscii.AsSpan(pdfSizeStart, pdfSizeEnd - pdfSizeStart), out pdfObjectCount);
}
bool xrefEntriesOk = pdfObjectCount > 1;
int xrefEntryCursor = firstXrefEntry;
for (int i = 1; i < pdfObjectCount && xrefEntriesOk; i++)
{
    int entryOffset = -1;
    if (xrefEntryCursor > 0)
    {
        int.TryParse(pdfAscii.AsSpan(xrefEntryCursor, 10), out entryOffset);
    }
    string expectedHeader = $"{i} 0 obj";
    xrefEntriesOk = entryOffset > 0 && entryOffset + expectedHeader.Length <= pdfAscii.Length &&
        pdfAscii.Substring(entryOffset, expectedHeader.Length) == expectedHeader;
    xrefEntryCursor = pdfAscii.IndexOf('\n', xrefEntryCursor) + 1;
}
// Every content stream's declared /Length must be followed by endstream after optional
// whitespace (the EOL before the keyword may or may not be counted per writer style).
bool streamLengthsOk = true;
int streamCursor = 0;
while (true)
{
    // Anchored with the leading newline so the "stream" inside "endstream" never matches.
    int streamAt = pdfAscii.IndexOf("\nstream\n", streamCursor, StringComparison.Ordinal);
    if (streamAt < 0)
    {
        break;
    }
    int dataStart = streamAt + "\nstream\n".Length;
    int lengthAt = pdfAscii.LastIndexOf("/Length ", streamAt, StringComparison.Ordinal);
    int declaredLength = -1;
    if (lengthAt >= 0)
    {
        int lengthValueStart = lengthAt + "/Length ".Length;
        int lengthValueEnd = pdfAscii.IndexOf(' ', lengthValueStart);
        int.TryParse(pdfAscii.AsSpan(lengthValueStart, lengthValueEnd - lengthValueStart), out declaredLength);
    }
    int afterData = declaredLength >= 0 ? dataStart + declaredLength : -1;
    while (afterData >= 0 && afterData < pdfAscii.Length &&
        (pdfAscii[afterData] == '\r' || pdfAscii[afterData] == '\n' || pdfAscii[afterData] == ' '))
    {
        afterData++;
    }
    bool thisStreamOk = afterData >= 0 && afterData + "endstream".Length <= pdfAscii.Length &&
        pdfAscii.Substring(afterData, "endstream".Length) == "endstream";
    if (!thisStreamOk)
    {
        streamLengthsOk = false;
    }
    streamCursor = thisStreamOk ? afterData + "endstream".Length : pdfAscii.Length;
}
bool pdfOk = pdfAscii.StartsWith("%PDF-1.4", StringComparison.Ordinal) &&
    pdfAscii.EndsWith("%%EOF\n", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Type /Catalog", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Type /Pages", StringComparison.Ordinal) &&
    pdfAscii.Contains("/Subtype /Type1", StringComparison.Ordinal) &&
    pdfAscii.Contains("(Escapes \\(paren\\) and \\\\ slash)", StringComparison.Ordinal) &&
    pdfAscii.Contains("\\351", StringComparison.Ordinal) &&
    pdfXrefOffset > 0 && pdfXrefOffset < pdfAscii.Length &&
    pdfAscii.Substring(pdfXrefOffset, 4) == "xref" &&
    firstObjectOffset > 0 && pdfAscii.Substring(firstObjectOffset, 7) == "1 0 obj" &&
    xrefEntriesOk && streamLengthsOk;
Console.WriteLine($"[verify] printing text pdf bytes={textPdf.Length} xref={pdfXrefOffset} objects={pdfObjectCount} xrefEntriesOk={xrefEntriesOk} streamLengthsOk={streamLengthsOk} assert={pdfOk}");
if (!pdfOk)
{
    throw new InvalidOperationException("the text-to-PDF document structure assertion failed");
}

byte[] longPdf = OpenHarmonyPrinting.BuildTextPdf(
    string.Join("\n", Enumerable.Range(0, 120).Select(i => $"print line {i}")));
string longPdfAscii = System.Text.Encoding.ASCII.GetString(longPdf);
bool longPdfOk = longPdfAscii.Contains("/Count 3", StringComparison.Ordinal) && longPdf.Length > textPdf.Length;
Console.WriteLine($"[verify] printing text pdf pagination bytes={longPdf.Length} pages=3 assert={longPdfOk}");
if (!longPdfOk)
{
    throw new InvalidOperationException("the multi-page text-to-PDF assertion failed");
}

string sanitized = OpenHarmonyPrinting.SanitizeJobName("verify text.pdf");
bool sanitizeOk = sanitized == "verify_text_pdf" &&
    OpenHarmonyPrinting.SanitizeJobName("  ") == "print" &&
    OpenHarmonyPrinting.SanitizeJobName(null) == "print";
Console.WriteLine($"[verify] printing job name sanitizer 'verify text.pdf'->'{sanitized}' empty->'{OpenHarmonyPrinting.SanitizeJobName(null)}' assert={sanitizeOk}");
if (!sanitizeOk)
{
    throw new InvalidOperationException("the print job name sanitizer assertion failed");
}

// Gap 6 follow-up: Battery/DeviceDisplay (Essentials) over the shell push bridge
// (host.notifyBattery / host.notifyDisplay -> the ModuleInitializer-installed implementations).
// Off-device the native registration is guarded, the properties stay at the documented defaults
// and the payload parsers are exercised with the exact shell formats.
bool batteryInstalled = Microsoft.Maui.Devices.Battery.Default is OpenHarmonyBattery;
Console.WriteLine($"[verify] battery default installed={batteryInstalled} type={Microsoft.Maui.Devices.Battery.Default.GetType().Name} instance={ReferenceEquals(Microsoft.Maui.Devices.Battery.Default, OpenHarmonyBattery.Instance)}");
if (!batteryInstalled)
{
    throw new InvalidOperationException("OpenHarmonyBattery was not installed as the Essentials Battery default");
}

OpenHarmonyBatterySnapshot? charging = OpenHarmonyBattery.ParseState("85\t1\t2\t1\t600");
OpenHarmonyBatterySnapshot? discharging = OpenHarmonyBattery.ParseState("50\t2\t1\t1\t601");
OpenHarmonyBatterySnapshot? fullAbsent = OpenHarmonyBattery.ParseState("100\t3\t3\t0\t603");
OpenHarmonyBatterySnapshot? ignored = OpenHarmonyBattery.ParseState("100\t3\t3\t0\t650");
bool batteryParsedOk = charging is { ChargeLevel: 0.85, State: BatteryState.Charging, PowerSource: BatteryPowerSource.Usb, EnergySaver: EnergySaverStatus.Off } &&
    discharging is { ChargeLevel: 0.5, State: BatteryState.Discharging, PowerSource: BatteryPowerSource.AC, EnergySaver: EnergySaverStatus.On } &&
    fullAbsent is { ChargeLevel: 1.0, State: BatteryState.NotPresent, PowerSource: BatteryPowerSource.Wireless, EnergySaver: EnergySaverStatus.On } &&
    ignored is { State: BatteryState.NotPresent, EnergySaver: EnergySaverStatus.On } &&
    OpenHarmonyBattery.ParseState("85\t1") is null &&
    OpenHarmonyBattery.ParseState("a\tb\tc\td\te") is null &&
    OpenHarmonyBattery.ParseState(null) is null;
Console.WriteLine($"[verify] battery parser charging={charging?.ChargeLevel}/{charging?.State}/{charging?.PowerSource}/{charging?.EnergySaver} discharging={discharging?.ChargeLevel}/{discharging?.State}/{discharging?.PowerSource}/{discharging?.EnergySaver} absent={fullAbsent?.State} customSaver={ignored?.EnergySaver} malformedNull={OpenHarmonyBattery.ParseState("85\t1") is null} assert={batteryParsedOk}");
if (!batteryParsedOk)
{
    throw new InvalidOperationException("the battery payload parser assertion failed");
}

bool batteryOffDeviceOk = true;
double batteryLevel = -1;
BatteryState batteryState = BatteryState.Unknown;
BatteryPowerSource batterySource = BatteryPowerSource.Unknown;
bool batteryEvents = false;
bool saverEvents = false;
EventHandler<BatteryInfoChangedEventArgs> onBatteryInfoChanged = (_, e) =>
{
    batteryLevel = e.ChargeLevel;
    batteryState = e.State;
    batterySource = e.PowerSource;
    batteryEvents = true;
};
EventHandler<EnergySaverStatusChangedEventArgs> onEnergySaverChanged = (_, e) =>
{
    saverEvents = e.EnergySaverStatus == EnergySaverStatus.On;
};
try
{
    Microsoft.Maui.Devices.Battery.BatteryInfoChanged += onBatteryInfoChanged;
    Microsoft.Maui.Devices.Battery.EnergySaverStatusChanged += onEnergySaverChanged;
    batteryOffDeviceOk = Microsoft.Maui.Devices.Battery.ChargeLevel == 0 &&
        Microsoft.Maui.Devices.Battery.State == BatteryState.Unknown &&
        Microsoft.Maui.Devices.Battery.PowerSource == BatteryPowerSource.Unknown &&
        Microsoft.Maui.Devices.Battery.EnergySaverStatus == EnergySaverStatus.Unknown;
    // The native-shaped payload push is the same path the host callback runs on-device.
    OpenHarmonyBattery.OnBatteryPayload("42\t2\t2\t1\t650");
    OpenHarmonyBattery.OnBatteryPayload("garbage");
}
catch (Exception ex)
{
    batteryOffDeviceOk = false;
    Console.WriteLine($"[verify] battery payload push threw {ex.GetType().Name}: {ex.Message}");
}
finally
{
    Microsoft.Maui.Devices.Battery.BatteryInfoChanged -= onBatteryInfoChanged;
    Microsoft.Maui.Devices.Battery.EnergySaverStatusChanged -= onEnergySaverChanged;
}
bool batteryPushOk = batteryOffDeviceOk && batteryEvents && saverEvents && batteryLevel == 0.42 &&
    batteryState == BatteryState.Discharging && batterySource == BatteryPowerSource.Usb &&
    Microsoft.Maui.Devices.Battery.EnergySaverStatus == EnergySaverStatus.On;
Console.WriteLine($"[verify] battery push level={batteryLevel} state={batteryState} source={batterySource} saver={Microsoft.Maui.Devices.Battery.EnergySaverStatus} infoEvents={batteryEvents} saverEvents={saverEvents} noThrow={batteryOffDeviceOk} assert={batteryPushOk}");
if (!batteryPushOk)
{
    throw new InvalidOperationException("the battery payload push assertion failed");
}

bool displayInstalled = Microsoft.Maui.Devices.DeviceDisplay.Current is OpenHarmonyDeviceDisplay;
Console.WriteLine($"[verify] display default installed={displayInstalled} type={Microsoft.Maui.Devices.DeviceDisplay.Current.GetType().Name} instance={ReferenceEquals(Microsoft.Maui.Devices.DeviceDisplay.Current, OpenHarmonyDeviceDisplay.Instance)}");
if (!displayInstalled)
{
    throw new InvalidOperationException("OpenHarmonyDeviceDisplay was not installed as the Essentials DeviceDisplay current");
}

DisplayInfo emptyInfo = Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfo;
DisplayInfo? portrait = OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0\t60\t0");
DisplayInfo? landscape = OpenHarmonyDeviceDisplay.ParseDisplayInfo("2340\t1080\t320\t3\t90\t3");
DisplayInfo? inferred = OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0\t60");
bool displayParsedOk = portrait is { Width: 1080, Height: 2340, Density: 3.0, Rotation: DisplayRotation.Rotation0, Orientation: DisplayOrientation.Portrait, RefreshRate: 60 } &&
    landscape is { Width: 2340, Height: 1080, Density: 2.0, Rotation: DisplayRotation.Rotation270, Orientation: DisplayOrientation.Landscape, RefreshRate: 90 } &&
    inferred is { Orientation: DisplayOrientation.Portrait } &&
    emptyInfo is { Width: 0, Height: 0, Density: 1, Rotation: DisplayRotation.Unknown, Orientation: DisplayOrientation.Unknown } &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo("x\ty\tz\t0\t60\t0") is null &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo("1080\t2340\t480\t0") is null &&
    OpenHarmonyDeviceDisplay.ParseDisplayInfo(null) is null;
Console.WriteLine($"[verify] display parser portrait={portrait?.Width}x{portrait?.Height} density={portrait?.Density} rotation={portrait?.Rotation} orientation={portrait?.Orientation} landscape={landscape?.Width}x{landscape?.Height} rotation270={landscape?.Rotation == DisplayRotation.Rotation270} inferredOrientation={inferred?.Orientation} malformedNull={OpenHarmonyDeviceDisplay.ParseDisplayInfo("x\ty\tz\t0\t60\t0") is null} assert={displayParsedOk}");
if (!displayParsedOk)
{
    throw new InvalidOperationException("the display payload parser assertion failed");
}

DisplayInfo? changedInfo = null;
int displayChangedCount = 0;
EventHandler<DisplayInfoChangedEventArgs> onDisplayChanged = (_, e) =>
{
    changedInfo = e.DisplayInfo;
    displayChangedCount++;
};
bool displayPushOk;
try
{
    Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfoChanged += onDisplayChanged;
    OpenHarmonyDeviceDisplay.OnDisplayPayload("1080\t2340\t480\t0\t60\t0");
    DisplayInfo first = changedInfo ?? throw new InvalidOperationException("the display change event did not deliver a display info");
    OpenHarmonyDeviceDisplay.OnDisplayPayload("1080\t2340\t480\t0\t60\t0");   // identical -> no second raise
    OpenHarmonyDeviceDisplay.OnDisplayPayload("2340\t1080\t320\t3\t90\t3");
    OpenHarmonyDeviceDisplay.OnDisplayPayload("garbage");
    displayPushOk = displayChangedCount == 2 && first.Width == 1080 && first.Density == 3.0 &&
        changedInfo is { Width: 2340, Rotation: DisplayRotation.Rotation270 } &&
        Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfo.Width == 2340;
}
catch (Exception ex)
{
    displayPushOk = false;
    Console.WriteLine($"[verify] display payload push threw {ex.GetType().Name}: {ex.Message}");
}
finally
{
    Microsoft.Maui.Devices.DeviceDisplay.MainDisplayInfoChanged -= onDisplayChanged;
}
bool keepScreenOnOk = !Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn;
try
{
    Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn = true;
    keepScreenOnOk = !Microsoft.Maui.Devices.DeviceDisplay.KeepScreenOn;
}
catch (Exception)
{
    keepScreenOnOk = false;
}
Console.WriteLine($"[verify] display push changed={displayChangedCount} final={changedInfo?.Width}x{changedInfo?.Height} density={changedInfo?.Density} rotation={changedInfo?.Rotation} keepScreenOnFalse={keepScreenOnOk} noThrow={displayPushOk}");
if (!displayPushOk || !keepScreenOnOk)
{
    throw new InvalidOperationException("the display payload push assertion failed");
}
Console.WriteLine($"[verify] display off-device info={emptyInfo.Width}x{emptyInfo.Height} density={emptyInfo.Density} rotation={emptyInfo.Rotation} orientation={emptyInfo.Orientation} (empty default asserted)");

// ---- R2b: accessibility publish contract (managed <-> C) and value mapping -------------------
// The defect fixed here was an argument-count drift: the managed DllImport declared hint as its
// 6th argument while ohos_host_accessibility_node had no hint parameter, so under AAPCS64
// flags/actions were delivered shifted on device (flags=3/actions=0x10 arrived as
// flags=68151328/actions=3). The check below reflects the managed signature and parses the C
// definition plus the shared header, so any arity/type/name drift fails off-device.
static string? FindHostSource(string relativePath)
{
    var roots = new List<string?>
    {
        Environment.GetEnvironmentVariable("OHOS_WORKLOAD_ROOT"),
        Environment.GetEnvironmentVariable("OHOS_HOST_SRC"),
        AppContext.BaseDirectory,
        Directory.GetCurrentDirectory(),
        typeof(TestApp).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "MauiSliceDir")?.Value,
    };
    foreach (string? root in roots)
    {
        if (string.IsNullOrEmpty(root))
        {
            continue;
        }
        string start = Path.GetFullPath(root);
        for (DirectoryInfo? dir = new DirectoryInfo(start); dir is not null; dir = dir.Parent)
        {
            foreach (string candidate in new[]
            {
                Path.Combine(dir.FullName, relativePath),
                Path.Combine(dir.FullName, "ohos-workload", relativePath),
            })
            {
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
        }
    }
    return null;
}

// Parameter list between the parentheses of "name(", depth-aware because C types may carry
// parentheses in more general signatures (not in this one, but the locator stays honest).
static string? ExtractParameterList(string source, string functionName)
{
    int nameAt = source.IndexOf(functionName + "(", StringComparison.Ordinal);
    if (nameAt < 0)
    {
        return null;
    }
    int openAt = nameAt + functionName.Length;
    int depth = 0;
    for (int i = openAt; i < source.Length; i++)
    {
        if (source[i] == '(')
        {
            depth++;
        }
        else if (source[i] == ')')
        {
            depth--;
            if (depth == 0)
            {
                return source.Substring(openAt + 1, i - openAt - 1);
            }
        }
    }
    return null;
}

static string[] SplitParameters(string list) => list.Split(',').Select(p => p.Trim()).ToArray();
static string NormalizeParameterName(string name) => name.Replace("_", string.Empty).ToLowerInvariant();
static string NativeParameterName(string parameter) =>
    parameter.Split(' ', StringSplitOptions.RemoveEmptyEntries).Last().TrimStart('*');
static char ManagedKind(Type type) => type == typeof(int) ? 'i'
    : type == typeof(float) ? 'f'
    : type == typeof(double) ? 'd'
    : type == typeof(string) ? 's' : '?';
static char NativeKind(string parameter) => parameter.Contains("char*") ? 's'
    : parameter.Contains("double") ? 'd'
    : parameter.Contains("float") ? 'f'
    : parameter.Contains("int") ? 'i' : '?';
static bool HasUtf8Marshal(ParameterInfo parameter) =>
    parameter.GetCustomAttribute<MarshalAsAttribute>()?.Value == UnmanagedType.LPUTF8Str;

string? cSourcePath = FindHostSource("src/OpenHarmonyHost/openharmony_host.c");
string? hSourcePath = FindHostSource("src/OpenHarmonyHost/openharmony_host.h");
string? cSource = cSourcePath is null ? null : File.ReadAllText(cSourcePath);
string? hSource = hSourcePath is null ? null : File.ReadAllText(hSourcePath);
MethodInfo? nodePinvoke = typeof(OpenHarmonyAccessibility).GetMethod(
    "AccessibilityNode", BindingFlags.NonPublic | BindingFlags.Static);
string? nativeNodeList = cSource is null ? null : ExtractParameterList(cSource, "ohos_host_accessibility_node");
string[] nativeNodeParameters = nativeNodeList is null ? Array.Empty<string>() : SplitParameters(nativeNodeList);
ParameterInfo[] managedNodeParameters = nodePinvoke?.GetParameters() ?? Array.Empty<ParameterInfo>();
bool nodeCountOk = managedNodeParameters.Length == 16 && nativeNodeParameters.Length == 16;
bool nodeNamesOk = nodeCountOk && managedNodeParameters
    .Select(p => NormalizeParameterName(p.Name ?? string.Empty))
    .SequenceEqual(nativeNodeParameters.Select(p => NormalizeParameterName(NativeParameterName(p))));
bool nodeTypesOk = nodeCountOk && managedNodeParameters
    .Select(p => ManagedKind(p.ParameterType))
    .SequenceEqual(nativeNodeParameters.Select(NativeKind));
bool nodeMarshalOk = nodeCountOk && managedNodeParameters
    .Where(p => p.ParameterType == typeof(string)).All(HasUtf8Marshal);
string? nativeGetList = cSource is null ? null : ExtractParameterList(cSource, "ohos_host_accessibility_get");
string[] nativeGetParameters = nativeGetList is null ? Array.Empty<string>() : SplitParameters(nativeGetList);
string? headerNodeList = hSource is null ? null : ExtractParameterList(hSource, "ohos_host_accessibility_node");
string[] headerNodeParameters = headerNodeList is null ? Array.Empty<string>() : SplitParameters(headerNodeList);
bool contractOk = nodeCountOk && nodeNamesOk && nodeTypesOk && nodeMarshalOk &&
    nativeGetParameters.Length == 17 && headerNodeParameters.Length == 16;
Console.WriteLine($"[verify] a11y node contract managedArgs={managedNodeParameters.Length} nativeArgs={nativeNodeParameters.Length} names={nodeNamesOk} types={nodeTypesOk} utf8={nodeMarshalOk} nativeGetArgs={nativeGetParameters.Length} headerArgs={headerNodeParameters.Length} source='{cSourcePath ?? "<missing>"}' assert={contractOk}");
if (!contractOk)
{
    throw new InvalidOperationException(
        $"the ohos_host_accessibility_node publish contract drifted: managed={managedNodeParameters.Length} " +
        $"native={nativeNodeParameters.Length} names={nodeNamesOk} types={nodeTypesOk} utf8={nodeMarshalOk} " +
        $"nativeGet={nativeGetParameters.Length} header={headerNodeParameters.Length} source={cSourcePath ?? "<missing>"}");
}

// Value mapping: range is published only where the control has one (slider Minimum/Maximum/
// Value, progress 0/1/Progress), checked is 0/1 only for toggles, and every other role carries
// the absent markers (range NaN/NaN, checked -1). The host skips SetRangeInfo for an invalid
// range and SetChecked for -1, so these are the values a device would announce.
var rangeProbe = new VerticalStackLayout
{
    Children =
    {
        new Slider { Minimum = -5, Maximum = 15, Value = 7.5 },
        new ProgressBar { Progress = 0.25 },
        new Switch { IsToggled = true },   // Controls.Switch exposes the ISwitch.IsOn value as IsToggled
        new CheckBox { IsChecked = false },
        new Label { Text = "plain" },
    },
};
var rangeProbePage = new ContentPage { Content = rangeProbe };
OpenHarmonyHandlerConnector.ConnectTree(rangeProbePage);
rangeProbePage.Measure(1080, 600);
rangeProbePage.Arrange(new Rect(0, 0, 1080, 600));
OpenHarmonyAccessibility.Refresh(rangeProbePage);
var sliderNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Role == "slider");
var progressNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Role == "progress");
var switchNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Role == "switch");
var checkBoxNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Role == "checkBox");
var plainNode = OpenHarmonyAccessibility.Nodes.FirstOrDefault(n => n.Text == "plain");
bool sliderRangeOk = sliderNode is { RangeMin: -5, RangeMax: 15, RangeCurrent: 7.5, Checked: -1 };
bool progressRangeOk = progressNode is { RangeMin: 0, RangeMax: 1, RangeCurrent: 0.25, Checked: -1 };
bool switchCheckedOk = switchNode is { Checked: 1 };
bool checkBoxCheckedOk = checkBoxNode is { Checked: 0 };
bool plainAbsentOk = plainNode is not null && double.IsNaN(plainNode.RangeMin) &&
    double.IsNaN(plainNode.RangeMax) && plainNode.RangeCurrent == 0 && plainNode.Checked == -1;
Console.WriteLine($"[verify] a11y range slider={sliderNode?.RangeMin}/{sliderNode?.RangeMax}/{sliderNode?.RangeCurrent} progress={progressNode?.RangeMin}/{progressNode?.RangeMax}/{progressNode?.RangeCurrent} map={sliderRangeOk && progressRangeOk}");
Console.WriteLine($"[verify] a11y checked switch={switchNode?.Checked} checkbox={checkBoxNode?.Checked} plain={plainNode?.Checked} absentRange={plainNode is not null && double.IsNaN(plainNode.RangeMin)} map={switchCheckedOk && checkBoxCheckedOk && plainAbsentOk}");
if (!sliderRangeOk || !progressRangeOk || !switchCheckedOk || !checkBoxCheckedOk || !plainAbsentOk)
{
    throw new InvalidOperationException("the accessibility range/checked value mapping assertion failed");
}

// A slider drag changes neither text nor bounds, so the frame diff must still flag a state
// update or the host would never republish the new range; an unchanged frame must stay quiet
// (an absent NaN range must not look changed on every frame).
var sliderControl = (Slider)rangeProbe.Children[0];
OpenHarmonyAccessibility.Publish();       // first probe frame: publishes/diffs
OpenHarmonyAccessibility.Refresh(rangeProbePage);
OpenHarmonyAccessibility.Publish();       // identical frame
bool unchangedQuiet = OpenHarmonyAccessibility.PendingEventCount == 0;
sliderControl.Value = 8.5;
OpenHarmonyAccessibility.Refresh(rangeProbePage);
OpenHarmonyAccessibility.Publish();
bool valueChangeSeen =
    (OpenHarmonyAccessibility.PendingEventCount & OpenHarmonyAccessibility.EventPageStateUpdate) != 0;
Console.WriteLine($"[verify] a11y range diff unchangedQuiet={unchangedQuiet} valueChangeStateUpdate={valueChangeSeen} pending=0x{OpenHarmonyAccessibility.PendingEventCount:x}");
if (!unchangedQuiet || !valueChangeSeen)
{
    throw new InvalidOperationException("the accessibility range frame diff assertion failed");
}

// ---- S-series: BlazorWebView, a11y node count, flashlight, file sharing ------------------------
// The four feature slices delivered alongside the S-series packs, checked deterministically and
// off-device safe (no host library is loaded and no device state is assumed). S1 reflects the
// BlazorWebView managed path out of its source because the handler only compiles when
// OPENHARMONY_BLAZOR_WEBVIEW is defined (this harness leaves it undefined), and exercises the
// unconditionally compiled asset mapping the handler's file provider delegates to at run time;
// S2 probes the accessibility node-count export the shell's self-check reads; S3 pins the torch
// bridge's host entry point and proves the installed Essentials default degrades without
// throwing; S4 exercises the share dispatch, MIME map and file:// URI shape. Device-only halves
// (torch LED, receiver read grant, Blazor start(), a11y provider attach) stay unverifiable
// off-device and are documented rather than asserted.

// S1a: handler + manager + registration (source contract, no OPENHARMONY_BLAZOR_WEBVIEW here).
string? s1HandlerPath = FindHostSource("OpenHarmonyBlazorWebViewHandler.cs");
string s1Handler = s1HandlerPath is null ? string.Empty : File.ReadAllText(s1HandlerPath);
string? s1ExtensionsPath = FindHostSource("MauiOpenHarmonyExtensions.cs");
string s1Extensions = s1ExtensionsPath is null ? string.Empty : File.ReadAllText(s1ExtensionsPath);
bool s1HandlerOk = s1Handler.Contains("OpenHarmonyBlazorWebViewHandler : OpenHarmonyViewHandler<IBlazorWebView>, IBlazorWebViewHandler") &&
    s1Handler.Contains("StartWebViewCoreIfPossible") &&
    s1Handler.Contains("OpenHarmonyWebViewManager") &&
    s1Handler.Contains("AddToWebViewManagerAsync") &&
    s1Handler.Contains("RemoveFromWebViewManagerAsync");
bool s1RegistrationOk = s1Extensions.Contains("#if OPENHARMONY_BLAZOR_WEBVIEW") &&
    s1Extensions.Contains("[typeof(Microsoft.AspNetCore.Components.WebView.Maui.IBlazorWebView)] = typeof(OpenHarmonyBlazorWebViewHandler)");
bool s1SourceOk = s1HandlerOk && s1RegistrationOk;
Console.WriteLine($"[verify] s1 blazor handler/manager handler={s1Handler.Length > 0} startup={s1Handler.Contains("StartWebViewCoreIfPossible")} rootComponents={s1Handler.Contains("AddToWebViewManagerAsync")} registered={s1RegistrationOk} gated={s1Extensions.Contains("#if OPENHARMONY_BLAZOR_WEBVIEW")} source='{s1HandlerPath ?? "<missing>"}' assert={s1SourceOk}");
if (!s1SourceOk)
{
    throw new InvalidOperationException("the S1 BlazorWebView handler/manager/registration path is missing from the platform slice sources");
}

// S1b: file provider + root asset mapping (the file provider resolves every request through
// OpenHarmonyBlazorWebView.ResolveAssetPath, which is compiled unconditionally and is asserted
// at run time: origin/query/fragment stripping, the default host file, the framework directory
// and the escape rejections that keep a resolved asset inside the content root).
string s1AppDirectory = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "verify-blazor-payload"));
string? s1ContentRoot = OpenHarmonyBlazorWebView.ResolveContentRoot(s1AppDirectory);
string? s1IndexAsset = OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "");
string? s1FrameworkAsset = OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "_framework/blazor.webview.js");
string? s1UrlAsset = OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "https://0.0.0.0/_framework/blazor.webview.js?v=1#frag");
bool s1MappingOk = s1ContentRoot == Path.GetFullPath(Path.Combine(s1AppDirectory, OpenHarmonyBlazorWebView.ContentRoot)) &&
    s1IndexAsset == Path.GetFullPath(Path.Combine(s1AppDirectory, OpenHarmonyBlazorWebView.ContentRoot, OpenHarmonyBlazorWebView.DefaultHostFile)) &&
    s1FrameworkAsset == Path.GetFullPath(Path.Combine(s1AppDirectory, OpenHarmonyBlazorWebView.ContentRoot, "_framework", "blazor.webview.js")) &&
    s1UrlAsset == s1FrameworkAsset;
bool s1SafetyOk = OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "../escape.js") is null &&
    OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "a/../b.js") is null &&
    OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "css\\evil.css") is null &&
    OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "%2e%2e/escape.js") is null &&
    OpenHarmonyBlazorWebView.ResolveAssetPath(null, "index.html") is null &&
    OpenHarmonyBlazorWebView.ResolveAssetPath(s1AppDirectory, "index.html", "../root") is null;
bool s1ConstantsOk = OpenHarmonyBlazorWebView.AppOrigin == "https://0.0.0.0/" &&
    OpenHarmonyBlazorWebView.DefaultHostFile == "index.html" &&
    OpenHarmonyBlazorWebView.FrameworkDirectory == "_framework" &&
    OpenHarmonyBlazorWebView.IsFrameworkRequest("_framework/blazor.webview.js") &&
    !OpenHarmonyBlazorWebView.IsFrameworkRequest("css/app.css");
bool s1ProviderOk = s1Handler.Contains("OpenHarmonyBlazorFileProvider") && s1Handler.Contains("IFileProvider");
bool s1MappingAllOk = s1ProviderOk && s1MappingOk && s1SafetyOk && s1ConstantsOk;
Console.WriteLine($"[verify] s1 blazor file provider provider={s1ProviderOk} mapping={s1MappingOk} safety={s1SafetyOk} constants={s1ConstantsOk} root={s1ContentRoot} index='{s1IndexAsset}' framework='{s1FrameworkAsset}' assert={s1MappingAllOk}");
if (!s1MappingAllOk)
{
    throw new InvalidOperationException("the S1 BlazorWebView file-provider asset mapping assertion failed");
}

// S2a: the node-count export the ArkTS accessibility self-check reads
// (host.accessibilityNodeCount -> ohos_host_accessibility_node_count) is present under its own
// name in the C source, the header and the napi module table, so the 16-argument publish
// contract reflection never mistakes it for the publish function.
string? s2NapiPath = FindHostSource("src/OpenHarmonyHost/host_napi.cpp");
string s2Napi = s2NapiPath is null ? string.Empty : File.ReadAllText(s2NapiPath);
bool s2CExportOk = cSource?.Contains("int ohos_host_accessibility_node_count(void)") == true;
bool s2HeaderOk = hSource?.Contains("int ohos_host_accessibility_node_count(void);") == true;
bool s2NapiOk = s2Napi.Contains("napi_value AccessibilityNodeCount(") &&
    s2Napi.Contains("ohos_host_accessibility_node_count()") &&
    s2Napi.Contains("\"accessibilityNodeCount\"");
bool s2ExportOk = s2CExportOk && s2HeaderOk && s2NapiOk;
Console.WriteLine($"[verify] s2 a11y node-count export c={s2CExportOk} header={s2HeaderOk} napi={s2NapiOk} distinct={cSource?.Contains("int ohos_host_accessibility_count(void)") == true} source='{s2NapiPath ?? "<missing>"}' assert={s2ExportOk}");
if (!s2ExportOk)
{
    throw new InvalidOperationException("the S2 accessibility node-count export is missing from the native host sources");
}

// S2b: managed half of the same count. The shadow tree rebuilt for the live page has nodes, and
// the publish pass that would hand them to the host stays a guarded no-op without the host
// library (the count export would return 0), never throwing.
OpenHarmonyAccessibility.Refresh(navRoot);
int s2NodeCount = OpenHarmonyAccessibility.Nodes.Count;
bool s2PublishNoThrow = true;
try
{
    OpenHarmonyAccessibility.Publish();
}
catch (Exception ex)
{
    s2PublishNoThrow = false;
    Console.WriteLine($"[verify] s2 a11y node-count publish threw {ex.GetType().Name}: {ex.Message}");
}
bool s2RuntimeOk = s2NodeCount > 0 && s2PublishNoThrow &&
    OpenHarmonyAccessibility.Nodes.Count == s2NodeCount && OpenHarmonyAccessibility.LastPublishedCount == 0;
Console.WriteLine($"[verify] s2 a11y node-count managed nodes={s2NodeCount} published={OpenHarmonyAccessibility.LastPublishedCount} noThrow={s2PublishNoThrow} assert={s2RuntimeOk}");
if (!s2RuntimeOk)
{
    throw new InvalidOperationException("the S2 accessibility node-count runtime probe failed");
}

// S3a: the installed Essentials flashlight default is the slice implementation and every call
// degrades without throwing when the platform path is unavailable (the bridge reports support
// as false and TurnOn/TurnOff are logged no-ops instead of FeatureNotSupportedException).
var s3Flashlight = Microsoft.Maui.Devices.Flashlight.Default;
bool s3InstalledOk = s3Flashlight is OpenHarmonyFlashlight;
bool s3Supported = true;
bool s3TurnOnNoThrow = false;
bool s3TurnOffNoThrow = false;
try
{
    s3Supported = await s3Flashlight.IsSupportedAsync();
    await s3Flashlight.TurnOnAsync();
    s3TurnOnNoThrow = true;
    await s3Flashlight.TurnOffAsync();
    s3TurnOffNoThrow = true;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] s3 flashlight threw {ex.GetType().Name}: {ex.Message}");
}
bool s3RuntimeOk = s3InstalledOk && !s3Supported && s3TurnOnNoThrow && s3TurnOffNoThrow;
Console.WriteLine($"[verify] s3 flashlight default={s3Flashlight.GetType().Name} installed={s3InstalledOk} supported={s3Supported} turnOnNoThrow={s3TurnOnNoThrow} turnOffNoThrow={s3TurnOffNoThrow} assert={s3RuntimeOk}");
if (!s3RuntimeOk)
{
    throw new InvalidOperationException("the S3 flashlight default/degradation assertion failed");
}

// S3b: the managed bridge's P/Invoke entry point and opcodes are pinned, and the native host's
// torch export plus the shell sink registration are present in the source the pack is built from.
MethodInfo? s3FlashlightPinvoke = typeof(OpenHarmonyFlashlightBridge).GetMethod(
    "FlashlightSet", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? s3FlashlightImport = s3FlashlightPinvoke?.GetCustomAttribute<DllImportAttribute>();
bool s3EntryPointOk = s3FlashlightImport is not null &&
    s3FlashlightImport.EntryPoint == "ohos_host_flashlight_set" &&
    s3FlashlightImport.Value == "libopenharmonyhost.so";
bool s3OpcodesOk = OpenHarmonyFlashlightBridge.OffOp == 0 &&
    OpenHarmonyFlashlightBridge.OnOp == 1 &&
    OpenHarmonyFlashlightBridge.ProbeOp == 2;
bool s3NativeOk = s3EntryPointOk && s3OpcodesOk &&
    s2Napi.Contains("ohos_host_flashlight_set") && s2Napi.Contains("\"registerFlashlightSink\"");
Console.WriteLine($"[verify] s3 flashlight export entry='{s3FlashlightImport?.EntryPoint}' lib='{s3FlashlightImport?.Value}' opcodes={OpenHarmonyFlashlightBridge.OffOp}/{OpenHarmonyFlashlightBridge.OnOp}/{OpenHarmonyFlashlightBridge.ProbeOp} sink={s2Napi.Contains("\"registerFlashlightSink\"")} assert={s3NativeOk}");
if (!s3NativeOk)
{
    throw new InvalidOperationException("the S3 flashlight host export/sink contract drifted");
}

// S4a: the MIME map a file share sends as the Want type (extension, lower-cased; unknown -> */*).
string s4MimePdf = OpenHarmonyShare.MimeTypeForPath("/tmp/verify.PDF");
string s4MimePng = OpenHarmonyShare.MimeTypeForPath("verify.PNG");
string s4MimeTxt = OpenHarmonyShare.MimeTypeForPath("verify.txt");
string s4MimeDocx = OpenHarmonyShare.MimeTypeForPath("verify.docx");
string s4MimeUnknown = OpenHarmonyShare.MimeTypeForPath("verify.unknownext");
bool s4MimeOk = s4MimePdf == "application/pdf" && s4MimePng == "image/png" &&
    s4MimeTxt == "text/plain" &&
    s4MimeDocx == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" &&
    s4MimeUnknown == "*/*";
Console.WriteLine($"[verify] s4 share mime pdf={s4MimePdf} png={s4MimePng} txt={s4MimeTxt} docx={s4MimeDocx} unknown={s4MimeUnknown} assert={s4MimeOk}");
if (!s4MimeOk)
{
    throw new InvalidOperationException("the S4 share MIME map assertion failed");
}

// S4b: the file:// URI shape (absolute sandbox path -> file:///..., scheme passes through) and the
// off-device dispatch of ShareFileRequest / ShareMultipleFilesRequest / ShareTextRequest through
// the installed IShare default, which must complete without throwing when the ability bridge is
// absent. The want kind for single-file sharing is pinned to 3 (sendData + read grant in the
// shell), matching the shell's FLAG_AUTH_READ_URI_PERMISSION handling.
string s4UriAbsolute = OpenHarmonyShare.FileUriForPath("/data/storage/el2/base/tmp/verify-share.pdf");
string s4UriRelative = OpenHarmonyShare.FileUriForPath("verify-share.pdf");
string s4UriPassthrough = OpenHarmonyShare.FileUriForPath("file:///already/there.pdf");
bool s4UriOk = s4UriAbsolute == "file:///data/storage/el2/base/tmp/verify-share.pdf" &&
    s4UriRelative == "file:///verify-share.pdf" &&
    s4UriPassthrough == "file:///already/there.pdf";
bool s4DefaultOk = shareDefault is OpenHarmonyShare;
bool s4DispatchNoThrow = true;
bool s4SingleOk = false;
bool s4MultipleOk = false;
bool s4TextOk = false;
try
{
    await shareDefault.RequestAsync(new ShareFileRequest { Title = "verify", File = new ShareFile(probeFile) });
    s4SingleOk = true;
    await shareDefault.RequestAsync(new ShareMultipleFilesRequest
    {
        Title = "verify",
        Files = new List<ShareFile> { new(probeFile), new(imagePath) },
    });
    s4MultipleOk = true;
    await shareDefault.RequestAsync(new ShareTextRequest { Text = "verify share" });
    s4TextOk = true;
}
catch (Exception ex)
{
    s4DispatchNoThrow = false;
    Console.WriteLine($"[verify] s4 share dispatch threw {ex.GetType().Name}: {ex.Message}");
}
FieldInfo? s4KindField = typeof(OpenHarmonyAbilityBridge).GetField("KindShareFile", BindingFlags.NonPublic | BindingFlags.Static);
bool s4KindOk = s4KindField?.GetRawConstantValue()?.ToString() == "3";
bool s4DispatchOk = s4DefaultOk && s4KindOk && s4UriOk && s4DispatchNoThrow && s4SingleOk && s4MultipleOk && s4TextOk;
Console.WriteLine($"[verify] s4 share uri='{s4UriAbsolute}' relative='{s4UriRelative}' passthrough={s4UriPassthrough == "file:///already/there.pdf"} kind3={s4KindOk} dispatchNoThrow={s4DispatchNoThrow} single={s4SingleOk} multiple={s4MultipleOk} text={s4TextOk} assert={s4DispatchOk}");
if (!s4DispatchOk)
{
    throw new InvalidOperationException("the S4 share dispatch/URI assertion failed");
}

// ---- V8: on-demand app-context publish (native -> napi -> shell -> managed bridge) -------------
// V8 lets the ArkTS page publish the real app-context snapshot after startApp:
// ohos_host_set_app_context(json) copies the JSON, exports it through OHOS_HOST_APP_CONTEXT,
// replaces the snapshot ohos_host_get_app_context returns and re-emits it through the stored
// surface state; ohos_host_notify_context() re-emits the snapshot unchanged. The managed bridge
// re-reads the context in OpenHarmonyBridge.RefreshContext (environment first, native getter
// second) and OnSurfaceNative calls it before forwarding the event, so the replayed surface
// notification is the path a managed reader sees the new snapshot on. The checks below pin the C
// entries plus their header signatures, the napi wrappers and module-table names, the shell
// template's guarded XComponent onLoad call site, and then drive the managed seam off-device: the
// environment copy (the same OHOS_HOST_APP_CONTEXT variable the native export writes) is swapped
// between two snapshots and the private surface callback is invoked through reflection, so a
// re-published snapshot must be re-read and re-raised without a device.

// V8a: the native entries and their documented signatures. The definitions live in the C source,
// the declarations in the shared header; both must agree on argument name/type and the return
// type, so a rename/arity drift fails here instead of shipping a mismatched pack.
static string NormalizeNativeSignature(string? parameters) => parameters is null
    ? "<missing>"
    : string.Join(",", SplitParameters(parameters).Select(p => string.Concat(p.Where(c => !char.IsWhiteSpace(c)))));
string? v8SetDefinition = cSource is null ? null : ExtractParameterList(cSource, "ohos_host_set_app_context");
string? v8SetHeader = hSource is null ? null : ExtractParameterList(hSource, "ohos_host_set_app_context");
string? v8NotifyDefinition = cSource is null ? null : ExtractParameterList(cSource, "ohos_host_notify_context");
string? v8NotifyHeader = hSource is null ? null : ExtractParameterList(hSource, "ohos_host_notify_context");
string v8SetSignature = NormalizeNativeSignature(v8SetDefinition);
string v8NotifySignature = NormalizeNativeSignature(v8NotifyDefinition);
string v8SetHeaderSignature = NormalizeNativeSignature(v8SetHeader);
string v8NotifyHeaderSignature = NormalizeNativeSignature(v8NotifyHeader);
bool v8DefinitionsOk = cSource?.Contains("int ohos_host_set_app_context(const char* json)") == true &&
    cSource.Contains("int ohos_host_notify_context(void)") == true;
bool v8HeaderOk = hSource?.Contains("int ohos_host_set_app_context(const char* json);") == true &&
    hSource.Contains("int ohos_host_notify_context(void);") == true;
bool v8SignaturesOk = v8SetSignature == "constchar*json" && v8NotifySignature == "void" &&
    v8SetHeaderSignature == v8SetSignature && v8NotifyHeaderSignature == v8NotifySignature;
bool v8NativeContractOk = v8DefinitionsOk && v8HeaderOk && v8SignaturesOk;
Console.WriteLine($"[verify] v8 native context entries set='{v8SetSignature}' notify='{v8NotifySignature}' definitions={v8DefinitionsOk} header={v8HeaderOk} headerMatch={v8SetHeaderSignature == v8SetSignature && v8NotifyHeaderSignature == v8NotifySignature} source='{cSourcePath ?? "<missing>"}' assert={v8NativeContractOk}");
if (!v8NativeContractOk)
{
    throw new InvalidOperationException(
        $"the V8 app-context host entries drifted: definitions={v8DefinitionsOk} header={v8HeaderOk} " +
        $"set='{v8SetSignature}'/'{v8SetHeaderSignature}' notify='{v8NotifySignature}'/'{v8NotifyHeaderSignature}' " +
        $"source={cSourcePath ?? "<missing>"}");
}

// V8b: the publish side. set_app_context must export the environment copy (the source
// RefreshContext reads off-device too) and replace the getter snapshot, retiring the old one so
// a concurrent managed reader cannot be freed under.
bool v8ExportOk = cSource?.Contains("setenv(\"OHOS_HOST_APP_CONTEXT\", copy, 1);") == true &&
    cSource.Contains("OhosHostRetireContextSnapshot(g_app, g_app->context_json)") &&
    cSource.Contains("g_app->context_json = copy;");
Console.WriteLine($"[verify] v8 native publish export env={cSource?.Contains("setenv(\"OHOS_HOST_APP_CONTEXT\", copy, 1);") == true} retire={cSource?.Contains("OhosHostRetireContextSnapshot(g_app, g_app->context_json)") == true} replace={cSource?.Contains("g_app->context_json = copy;") == true} assert={v8ExportOk}");
if (!v8ExportOk)
{
    throw new InvalidOperationException("the V8 set_app_context export/replace/retire contract is missing from the native source");
}

// V8c: the re-emit side. notify_context must route through the stored surface replay, and that
// replay must only fire for a live created/changed surface - a destroyed one has no managed
// reader to notify, and the next real surface event re-reads the context anyway.
bool v8ReplayOk = cSource?.Contains("int ohos_host_notify_context(void) {") == true &&
    cSource.Contains("return OhosHostReplaySurfaceNotification();") &&
    cSource.Contains("g_app->bridge_surface(g_surface_window, g_surface_width, g_surface_height, g_surface_state);") &&
    cSource.Contains("g_surface_state != (int)OHOS_SURFACE_CREATED && g_surface_state != (int)OHOS_SURFACE_CHANGED");
Console.WriteLine($"[verify] v8 native notify replay notifyExit={cSource?.Contains("return OhosHostReplaySurfaceNotification();") == true} bridgeSurface={cSource?.Contains("g_app->bridge_surface(g_surface_window, g_surface_width, g_surface_height, g_surface_state);") == true} liveSurfaceGuard={cSource?.Contains("g_surface_state != (int)OHOS_SURFACE_CREATED && g_surface_state != (int)OHOS_SURFACE_CHANGED") == true} assert={v8ReplayOk}");
if (!v8ReplayOk)
{
    throw new InvalidOperationException("the V8 ohos_host_notify_context surface-replay contract is missing from the native source");
}

// V8d: the ownership/ordering guards: a publish before start_app is kept pending and adopted by
// start_app only when its own context is absent or does not name an appDir (a page publish racing
// the ability bootstrap must win over the stale start context), and replaced snapshots are freed
// at join, not under a reader.
bool v8PendingOk = cSource?.Contains("g_pending_context_json != NULL &&") == true &&
    cSource.Contains("(effective_context == NULL || !OhosHostContextNamesAppDir(effective_context))") &&
    cSource.Contains("free(g_pending_context_json);") &&
    cSource.Contains("OhosHostFreeRetiredContexts(handle);");
Console.WriteLine($"[verify] v8 native pending adopt={cSource?.Contains("(effective_context == NULL || !OhosHostContextNamesAppDir(effective_context))") == true} pendingFree={cSource?.Contains("free(g_pending_context_json);") == true} retireFreeAtJoin={cSource?.Contains("OhosHostFreeRetiredContexts(handle);") == true} assert={v8PendingOk}");
if (!v8PendingOk)
{
    throw new InvalidOperationException("the V8 pending/retired context ownership contract is missing from the native source");
}

// V8e: the napi wrappers: both names call the C entries, setAppContext returns the native rc,
// and both reject before touching the C API when the argument is missing.
string v8NapiWrappersSet = "napi_value SetAppContext(napi_env env, napi_callback_info info) {";
string v8NapiWrappersNotify = "napi_value NotifyAppContext(napi_env env, napi_callback_info info) {";
bool v8NapiWrappersOk = s2Napi.Contains(v8NapiWrappersSet) &&
    s2Napi.Contains(v8NapiWrappersNotify) &&
    s2Napi.Contains("int rc = ohos_host_set_app_context(json.c_str());") &&
    s2Napi.Contains("napi_value result = nullptr;\n    napi_create_int32(env, rc, &result);") &&
    s2Napi.Contains("napi_create_int32(env, ohos_host_notify_context(), &result);") &&
    s2Napi.Contains("setAppContext(contextJson) requires a non-empty string");
Console.WriteLine($"[verify] v8 napi wrappers set={s2Napi.Contains(v8NapiWrappersSet)} notify={s2Napi.Contains(v8NapiWrappersNotify)} rcReturn={s2Napi.Contains("napi_create_int32(env, rc, &result);")} argGuard={s2Napi.Contains("setAppContext(contextJson) requires a non-empty string")} source='{s2NapiPath ?? "<missing>"}' assert={v8NapiWrappersOk}");
if (!v8NapiWrappersOk)
{
    throw new InvalidOperationException("the V8 host.setAppContext/host.notifyAppContext wrappers are missing or do not call the C entries");
}

// V8f: the module table: both names must be registered on the napi exports the shell imports
// (a missing entry silently leaves typeof host.setAppContext === 'undefined' and the shell guard
// degrades to a no-op, so the publish would never reach the host).
bool v8NapiTableOk = s2Napi.Contains("{\"setAppContext\", nullptr, SetAppContext, nullptr, nullptr, nullptr, napi_default, nullptr}") &&
    s2Napi.Contains("{\"notifyAppContext\", nullptr, NotifyAppContext, nullptr, nullptr, nullptr, napi_default, nullptr}");
Console.WriteLine($"[verify] v8 napi module table setAppContext={s2Napi.Contains("{\"setAppContext\", nullptr, SetAppContext")} notifyAppContext={s2Napi.Contains("{\"notifyAppContext\", nullptr, NotifyAppContext")} assert={v8NapiTableOk}");
if (!v8NapiTableOk)
{
    throw new InvalidOperationException("the V8 setAppContext/notifyAppContext names are missing from the napi module table");
}

// V8g: the shell template (preview.24 is the current pack): publishAppContext is a private
// method with the typeof guard around the host call, so an older host library degrades to a
// no-op instead of throwing at page start.
string? v8ShellPath24 = FindHostSource("packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/ets/pages/Index.ets");
string v8Shell24 = v8ShellPath24 is null ? string.Empty : File.ReadAllText(v8ShellPath24);
bool v8ShellMethodOk = v8Shell24.Contains("private publishAppContext(): void {") &&
    v8Shell24.Contains("if (typeof host.setAppContext !== 'function') {") &&
    v8Shell24.Contains("} catch (contextError) {");
Console.WriteLine($"[verify] v8 shell publish method method={v8Shell24.Contains("private publishAppContext(): void {")} typeofGuard={v8Shell24.Contains("if (typeof host.setAppContext !== 'function') {")} guarded={v8Shell24.Contains("} catch (contextError) {")} source='{v8ShellPath24 ?? "<missing>"}' assert={v8ShellMethodOk}");
if (!v8ShellMethodOk)
{
    throw new InvalidOperationException("the shell template's guarded publishAppContext method is missing");
}

// V8h: the return contract at the call site: the rc is read as a number and a refusal is logged
// (the C/napi side returns 0 stored/kept, -1 rejected), so a failed publish stays observable.
bool v8ShellRcOk = v8Shell24.Contains("const rc: number = host.setAppContext(json) as number;") &&
    v8Shell24.Contains("if (rc !== 0) {") &&
    v8Shell24.Contains("console.error(`[maui] app context publish declined: ${rc}`);") &&
    v8Shell24.Contains("console.error(`[maui] app context publish failed: ${(contextError as Error).message}`);");
Console.WriteLine($"[verify] v8 shell rc rcNumber={v8Shell24.Contains("const rc: number = host.setAppContext(json) as number;")} refusalLog={v8Shell24.Contains("if (rc !== 0) {")} failureLog={v8Shell24.Contains("console.error(`[maui] app context publish failed:")} assert={v8ShellRcOk}");
if (!v8ShellRcOk)
{
    throw new InvalidOperationException("the shell template's setAppContext rc/error handling is missing");
}

// V8i: the call site: this.publishAppContext() must run from the XComponent onLoad after
// host.registerXComponent() bound the native surface - the surface becoming ready is what makes
// the host able to replay the notification the managed bridge re-reads.
static bool V8CallInsideOnLoad(string shell, string call, out int bindAt, out int callAt, out int onLoadAt, out int componentAt)
{
    bindAt = shell.IndexOf("host.registerXComponent();", StringComparison.Ordinal);
    callAt = shell.IndexOf(call, StringComparison.Ordinal);
    onLoadAt = bindAt < 0 ? -1 : shell.LastIndexOf(".onLoad(() => {", bindAt, StringComparison.Ordinal);
    componentAt = onLoadAt < 0 ? -1 : shell.LastIndexOf("XComponent(", onLoadAt, StringComparison.Ordinal);
    int onLoadEnd = callAt < 0 ? -1 : shell.IndexOf("})", callAt, StringComparison.Ordinal);
    return bindAt >= 0 && callAt > bindAt && onLoadAt > 0 && componentAt > 0 && onLoadEnd > callAt;
}
bool v8ShellCallSiteOk = V8CallInsideOnLoad(v8Shell24, "this.publishAppContext();",
    out int v8ShellBindAt, out int v8ShellCallAt, out int v8ShellOnLoadAt, out int v8ShellComponentAt);
Console.WriteLine($"[verify] v8 shell onLoad call site bind={v8ShellBindAt >= 0} publish={v8ShellCallAt > v8ShellBindAt} onLoad={v8ShellOnLoadAt > 0} xComponent={v8ShellComponentAt > 0} assert={v8ShellCallSiteOk}");
if (!v8ShellCallSiteOk)
{
    throw new InvalidOperationException("the shell template does not call publishAppContext inside the XComponent onLoad after registerXComponent");
}

// V8j: the published payload names the payload directory the hybrid registration extracts into
// (<filesDir>/dotnet) and carries the ability paths the managed bridge publishes; the keys are
// the ones OpenHarmonyAppContext parses.
bool v8ShellPayloadOk = v8Shell24.Contains("const payloadDir = `${context.filesDir}/dotnet`;") &&
    v8Shell24.Contains("appDir: payloadDir,") &&
    v8Shell24.Contains("filesDir: context.filesDir,") &&
    v8Shell24.Contains("cacheDir: context.cacheDir,") &&
    v8Shell24.Contains("bundleName: context.abilityInfo.bundleName,") &&
    v8Shell24.Contains("abilityName: context.abilityInfo.name,") &&
    v8Shell24.Contains("nodeContent: 0,");
Console.WriteLine($"[verify] v8 shell payload appDirDotnet={v8Shell24.Contains("const payloadDir = `${context.filesDir}/dotnet`;")} abilityPaths={v8Shell24.Contains("bundleName: context.abilityInfo.bundleName,") && v8Shell24.Contains("abilityName: context.abilityInfo.name,")} nodeContent={v8Shell24.Contains("nodeContent: 0,")} assert={v8ShellPayloadOk}");
if (!v8ShellPayloadOk)
{
    throw new InvalidOperationException("the shell template's app-context payload shape drifted");
}

// V8k: the V-series packs (22/23/24) carry the same shell block - the publish landed in the
// template the packs are built from, not just the working tree.
string[] v8ShellPackVersions = { "1.0.0-preview.22", "1.0.0-preview.23", "1.0.0-preview.24" };
int v8ShellPacksPresent = 0;
foreach (string v8PackVersion in v8ShellPackVersions)
{
    string? v8PackPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{v8PackVersion}/templates/ets/pages/Index.ets");
    string v8PackShell = v8PackPath is null ? string.Empty : File.ReadAllText(v8PackPath);
    v8ShellPacksPresent += v8PackShell.Contains("private publishAppContext(): void {") &&
        v8PackShell.Contains("this.publishAppContext();") ? 1 : 0;
}
bool v8ShellPacksOk = v8ShellPacksPresent == v8ShellPackVersions.Length;
Console.WriteLine($"[verify] v8 shell packs present={v8ShellPacksPresent}/{v8ShellPackVersions.Length} versions=22,23,24 assert={v8ShellPacksOk}");
if (!v8ShellPacksOk)
{
    throw new InvalidOperationException("the on-demand app-context publish is missing from one of the preview.22/23/24 shell templates");
}

// V8l: the managed bridge source contract the native replay rides: RefreshContext reads the
// OHOS_HOST_APP_CONTEXT copy first, the SurfaceChanged add accessor refreshes before it replays
// the last surface, and OnSurfaceNative refreshes before it forwards the event to its handlers.
string? v8HostingPath = FindHostSource("src/Microsoft.OpenHarmony.Hosting/OpenHarmonyApp.cs");
string v8Hosting = v8HostingPath is null ? string.Empty : File.ReadAllText(v8HostingPath);
int v8SurfaceEventAt = v8Hosting.IndexOf("public static event Action<OpenHarmonySurfaceInfo>? SurfaceChanged", StringComparison.Ordinal);
int v8SurfaceRefreshAt = v8SurfaceEventAt < 0 ? -1 : v8Hosting.IndexOf("RefreshContext();", v8SurfaceEventAt, StringComparison.Ordinal);
int v8SurfaceRemoveAt = v8SurfaceEventAt < 0 ? -1 : v8Hosting.IndexOf("remove", v8SurfaceEventAt, StringComparison.Ordinal);
int v8OnSurfaceAt = v8Hosting.IndexOf("private static void OnSurfaceNative(IntPtr window, int width, int height, int state)", StringComparison.Ordinal);
int v8OnSurfaceRefreshAt = v8OnSurfaceAt < 0 ? -1 : v8Hosting.IndexOf("RefreshContext();", v8OnSurfaceAt, StringComparison.Ordinal);
int v8OnSurfaceDispatchAt = v8OnSurfaceAt < 0 ? -1 : v8Hosting.IndexOf("handlers?.Invoke(info);", v8OnSurfaceAt, StringComparison.Ordinal);
bool v8EnvReadOk = v8Hosting.Contains("string env = Environment.GetEnvironmentVariable(\"OHOS_HOST_APP_CONTEXT\") ?? string.Empty;");
bool v8SurfaceAddRefreshOk = v8SurfaceEventAt >= 0 && v8SurfaceRefreshAt > v8SurfaceEventAt &&
    (v8SurfaceRemoveAt < 0 || v8SurfaceRefreshAt < v8SurfaceRemoveAt);
bool v8OnSurfaceRefreshOk = v8OnSurfaceAt >= 0 && v8OnSurfaceRefreshAt > v8OnSurfaceAt &&
    v8OnSurfaceRefreshAt < v8OnSurfaceDispatchAt;
bool v8BridgeContractOk = v8EnvReadOk && v8SurfaceAddRefreshOk && v8OnSurfaceRefreshOk;
Console.WriteLine($"[verify] v8 bridge contract envRead={v8EnvReadOk} surfaceAddRefresh={v8SurfaceAddRefreshOk} onSurfaceRefreshBeforeDispatch={v8OnSurfaceRefreshOk} source='{v8HostingPath ?? "<missing>"}' assert={v8BridgeContractOk}");
if (!v8BridgeContractOk)
{
    throw new InvalidOperationException("the managed bridge's context-refresh-on-surface contract drifted");
}

// V8m: the native registration hands the host exactly the surface callback this drill drives:
// Attach binds s_surfaceThunk to OnSurfaceNative and passes it to ohos_host_register_bridge, so
// the host's bridge_surface(...) replay ends in the handler below.
FieldInfo v8SurfaceThunkField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_surfaceThunk", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_surfaceThunk was not found; the V8 drill pins the native surface callback");
MethodInfo v8OnSurfaceNativeMethod = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetMethod("OnSurfaceNative", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.OnSurfaceNative was not found; the V8 drill drives it directly");
Delegate? v8SurfaceThunk = (Delegate?)v8SurfaceThunkField.GetValue(null);
bool v8SurfaceThunkOk = v8SurfaceThunk?.Method.Name == "OnSurfaceNative";
Console.WriteLine($"[verify] v8 bridge surface thunk bound={v8SurfaceThunk is not null} target='{v8SurfaceThunk?.Method.Name ?? "<null>"}' assert={v8SurfaceThunkOk}");
if (!v8SurfaceThunkOk)
{
    throw new InvalidOperationException("OpenHarmonyBridge.s_surfaceThunk is not bound to OnSurfaceNative; the native replay would not reach the context refresh");
}

// V8n: drive the managed seam. The native set_app_context exports the new snapshot through
// OHOS_HOST_APP_CONTEXT and replays the stored surface event; off-device the environment copy is
// the same source RefreshContext reads, so swap it between two snapshots, invoke the private
// surface callback (what the host's bridge_surface call lands on) and require the re-publish to
// be re-read and re-raised. State is captured first and restored at the end.
FieldInfo v8SurfaceStateField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_surface", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_surface was not found; the V8 drill simulates the stored surface state");
string? v8EnvBefore = Environment.GetEnvironmentVariable("OHOS_HOST_APP_CONTEXT");
Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext? v8ContextBefore =
    (Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext?)bridgeContextField.GetValue(null);
Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo? v8SurfaceBefore =
    (Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo?)v8SurfaceStateField.GetValue(null);
var v8InitializedSeen = new List<Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext>();
var v8SurfacesSeen = new List<Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo>();
void V8OnInitialized(Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext context) => v8InitializedSeen.Add(context);
void V8OnSurface(Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo surface) => v8SurfacesSeen.Add(surface);
string v8ContextAAppDir = "/data/storage/el2/base/tmp/verify-v8-context-a";
string v8ContextBAppDir = "/data/storage/el2/base/tmp/verify-v8-context-b";
static string V8ContextJson(string appDir) => JsonSerializer.Serialize(new
{
    appDir,
    filesDir = string.Empty,
    cacheDir = string.Empty,
    bundleName = "verify.v8",
    abilityName = "VerifyV8Ability",
    nodeContent = 0,
});
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", string.Empty);
bridgeContextField.SetValue(null, null);
v8SurfaceStateField.SetValue(null, null);
Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Initialized += V8OnInitialized;
Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.SurfaceChanged += V8OnSurface;

// (1) A snapshot exported after the surface is up is re-read: the Initialized event carries the
// new appDir and the Context property serves the replaced snapshot.
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", V8ContextJson(v8ContextAAppDir));
v8OnSurfaceNativeMethod.Invoke(null, new object[] { IntPtr.Zero, 1080, 1920, (int)Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceState.Changed });
bool v8PublishAOk = v8InitializedSeen.Count == 1 && v8InitializedSeen[0].AppDir == v8ContextAAppDir &&
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir == v8ContextAAppDir;
Console.WriteLine($"[verify] v8 bridge republish A contextEvents={v8InitializedSeen.Count} appDir='{Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir ?? "<null>"}' assert={v8PublishAOk}");
if (!v8PublishAOk)
{
    throw new InvalidOperationException("a surface re-published app context was not re-read into the Initialized event/Context");
}

// (2) The re-read really rode the surface event: the subscribers saw the stored surface with the
// XComponent size, and OpenHarmonyBridge.Surface serves it (the renderer's signal).
bool v8SurfaceAOk = v8SurfacesSeen.Count == 1 && v8SurfacesSeen[0].Width == 1080 &&
    v8SurfacesSeen[0].Height == 1920 &&
    v8SurfacesSeen[0].State == Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceState.Changed &&
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Surface is { Width: 1080, Height: 1920 };
Console.WriteLine($"[verify] v8 bridge republish surface events={v8SurfacesSeen.Count} width={(v8SurfacesSeen.Count > 0 ? v8SurfacesSeen[0].Width : -1)} height={(v8SurfacesSeen.Count > 0 ? v8SurfacesSeen[0].Height : -1)} state={(v8SurfacesSeen.Count > 0 ? v8SurfacesSeen[0].State.ToString() : "<none>")} stored={Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Surface is not null} assert={v8SurfaceAOk}");
if (!v8SurfaceAOk)
{
    throw new InvalidOperationException("the re-published context did not arrive on the surface notification path");
}

// (3) A second, changed snapshot replaces the first and is re-read again (the set_app_context
// path can run repeatedly; an unchanged snapshot must not re-raise, a changed one must).
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", V8ContextJson(v8ContextBAppDir));
v8OnSurfaceNativeMethod.Invoke(null, new object[] { IntPtr.Zero, 1080, 1920, (int)Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceState.Changed });
bool v8PublishBOk = v8InitializedSeen.Count == 2 && v8InitializedSeen[0].AppDir == v8ContextAAppDir &&
    v8InitializedSeen[1].AppDir == v8ContextBAppDir &&
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir == v8ContextBAppDir;
Console.WriteLine($"[verify] v8 bridge republish B contextEvents={v8InitializedSeen.Count} first='{v8InitializedSeen.FirstOrDefault()?.AppDir ?? "<none>"}' second='{v8InitializedSeen.Skip(1).FirstOrDefault()?.AppDir ?? "<none>"}' appDir='{Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir ?? "<null>"}' assert={v8PublishBOk}");
if (!v8PublishBOk)
{
    throw new InvalidOperationException("a changed re-published snapshot was not re-read after the first one");
}

// (4) notify_app_context re-emits the stored surface event without changing the snapshot: the
// context must stay put (no duplicate Initialized, same Context) while the surface event still
// fires - that is the 0/1 return distinction the shell/NAPI surface sees.
int v8NotifyEventsBefore = v8InitializedSeen.Count;
int v8NotifySurfacesBefore = v8SurfacesSeen.Count;
v8OnSurfaceNativeMethod.Invoke(null, new object[] { IntPtr.Zero, 1080, 1920, (int)Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceState.Changed });
bool v8NotifyOk = v8InitializedSeen.Count == v8NotifyEventsBefore &&
    v8SurfacesSeen.Count == v8NotifySurfacesBefore + 1 &&
    Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir == v8ContextBAppDir;
Console.WriteLine($"[verify] v8 bridge notify unchanged contextEvents=+{v8InitializedSeen.Count - v8NotifyEventsBefore} surfaceEvents=+{v8SurfacesSeen.Count - v8NotifySurfacesBefore} appDir='{Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Context?.AppDir ?? "<null>"}' assert={v8NotifyOk}");
if (!v8NotifyOk)
{
    throw new InvalidOperationException("replaying an unchanged snapshot re-raised the context or skipped the surface event");
}

// V8o: restore the captured state (environment copy, stored context, stored surface) so the
// remaining sections and the fuzz tail see exactly what they would have seen without the drill.
Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.Initialized -= V8OnInitialized;
Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.SurfaceChanged -= V8OnSurface;
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", v8EnvBefore);
bridgeContextField.SetValue(null, v8ContextBefore);
v8SurfaceStateField.SetValue(null, v8SurfaceBefore);
bool v8RestoredOk = (Environment.GetEnvironmentVariable("OHOS_HOST_APP_CONTEXT") ?? string.Empty) == (v8EnvBefore ?? string.Empty) &&
    ReferenceEquals(bridgeContextField.GetValue(null), v8ContextBefore) &&
    ReferenceEquals(v8SurfaceStateField.GetValue(null), v8SurfaceBefore);
Console.WriteLine($"[verify] v8 bridge seam restored env={v8RestoredOk} contextEvents={v8InitializedSeen.Count} surfaceEvents={v8SurfacesSeen.Count} assert={v8RestoredOk}");
if (!v8RestoredOk)
{
    throw new InvalidOperationException("the V8 bridge-seam drill did not restore the environment/context/surface state");
}

// ---- A-series: host-boundary lifetime guards (F1) and B3 per-document markers -----------------
// The F1 batch fixed the host-boundary lifetime races A1/A2/A5/A6/A7/A8 in the native host and
// the security batch bound the JS bridge deliveries to the document the shell served (B3).
// These pins parse the committed sources and assert the structural facts the fixes rely on, so
// a regression fails this off-device run instead of shipping a pack built from drifted sources.
// The B3 handler checks parse the Blazor handler source too, because that file only compiles
// with OPENHARMONY_BLAZOR_WEBVIEW (the S1 pins explain the same constraint).

// Shared structural helpers: a whole locked region (a lock call followed by an unlock call
// inside [start, end)) and an exact occurrence counter for the "exactly N call sites" checks.
static bool LockedRegion(string? source, string lockCall, string unlockCall, int start, int end)
{
    if (source is null || start < 0 || end <= start)
    {
        return false;
    }
    int lockAt = source.IndexOf(lockCall, start, StringComparison.Ordinal);
    if (lockAt < 0 || lockAt >= end)
    {
        return false;
    }
    int unlockAt = source.LastIndexOf(unlockCall, end - 1, end - start, StringComparison.Ordinal);
    return unlockAt > lockAt;
}

static int CountOccurrences(string? source, string needle)
{
    if (source is null)
    {
        return 0;
    }
    int count = 0;
    for (int at = source.IndexOf(needle, StringComparison.Ordinal); at >= 0;
         at = source.IndexOf(needle, at + needle.Length, StringComparison.Ordinal))
    {
        count++;
    }
    return count;
}

// A1: g_context_mutex serializes the pending/live context slots. start_app takes the pending
// snapshot out of the slot under the lock (adopting it only when its own context is absent or
// does not name an appDir), frees a superseded one under the same lock, and publishes g_app
// before unlocking; ohos_host_set_app_context replaces the pending slot under the same lock
// (the race was an ASan use-after-free in strdup), and the failed-launch clear holds it too.
int a1LockAt = cSource?.IndexOf("pthread_mutex_lock(&g_context_mutex);\n    char* adopted_pending = NULL;", StringComparison.Ordinal) ?? -1;
int a1AdoptAt = a1LockAt < 0 ? -1 : cSource!.IndexOf("adopted_pending = g_pending_context_json;", a1LockAt, StringComparison.Ordinal);
int a1AdoptClearAt = a1AdoptAt < 0 ? -1 : cSource!.IndexOf("g_pending_context_json = NULL;", a1AdoptAt, StringComparison.Ordinal);
int a1SupersedeAt = a1LockAt < 0 ? -1 : cSource!.IndexOf("free(g_pending_context_json);", a1LockAt, StringComparison.Ordinal);
int a1AdoptFreeAt = a1LockAt < 0 ? -1 : cSource!.IndexOf("free(adopted_pending);", a1LockAt, StringComparison.Ordinal);
int a1PublishAt = a1LockAt < 0 ? -1 : cSource!.IndexOf("g_app = handle;", a1LockAt, StringComparison.Ordinal);
int a1UnlockAt = a1PublishAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a1PublishAt, StringComparison.Ordinal);
int a1SetterAt = cSource?.IndexOf("int ohos_host_set_app_context(const char* json) {", StringComparison.Ordinal) ?? -1;
int a1SetterLockAt = a1SetterAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_lock(&g_context_mutex);", a1SetterAt, StringComparison.Ordinal);
int a1SetterReplaceAt = a1SetterLockAt < 0 ? -1 : cSource!.IndexOf("g_pending_context_json = copy;", a1SetterLockAt, StringComparison.Ordinal);
int a1SetterUnlockAt = a1SetterReplaceAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a1SetterReplaceAt, StringComparison.Ordinal);
bool a1MutexOk = cSource?.Contains("static pthread_mutex_t g_context_mutex = PTHREAD_MUTEX_INITIALIZER;") == true;
bool a1AdoptTakenOk = a1LockAt >= 0 && a1AdoptAt > a1LockAt && a1AdoptClearAt > a1AdoptAt;
bool a1AdoptFreedOk = a1AdoptFreeAt > a1AdoptClearAt && a1AdoptFreeAt < a1UnlockAt;
bool a1SupersedeOk = a1SupersedeAt > a1LockAt && a1SupersedeAt < a1UnlockAt && a1PublishAt > a1SupersedeAt && a1UnlockAt > a1PublishAt;
bool a1SetterOk = a1SetterLockAt > a1SetterAt && a1SetterReplaceAt > a1SetterLockAt && a1SetterUnlockAt > a1SetterReplaceAt;
bool a1EndLaunchOk = cSource?.Contains("static void OhosHostEndLaunch(void) {\n    pthread_mutex_lock(&g_context_mutex);\n    g_launch_in_progress = 0;\n    pthread_mutex_unlock(&g_context_mutex);") == true;
bool a1Ok = a1MutexOk && a1AdoptTakenOk && a1AdoptFreedOk && a1SupersedeOk && a1SetterOk && a1EndLaunchOk;
Console.WriteLine($"[verify] a1 context mutex mutex={a1MutexOk} adoptTaken={a1AdoptTakenOk} adoptFreed={a1AdoptFreedOk} supersededFreedUnderLock={a1SupersedeOk} publishUnderLock={a1PublishAt > a1SupersedeAt && a1UnlockAt > a1PublishAt} setterReplaceUnderLock={a1SetterOk} endLaunchUnderLock={a1EndLaunchOk} source='{cSourcePath ?? "<missing>"}' assert={a1Ok}");
if (!a1Ok)
{
    throw new InvalidOperationException(
        $"the A1 g_context_mutex adoption/supersede contract drifted: mutex={a1MutexOk} taken={a1AdoptTakenOk} " +
        $"freed={a1AdoptFreedOk} supersede={a1SupersedeOk} setter={a1SetterOk} endLaunch={a1EndLaunchOk} " +
        $"source={cSourcePath ?? "<missing>"}");
}

// A2: g_a11y_mutex guards the whole node-table API (begin/node/commit/count/get) against the
// NAPI provider reading on the ArkUI thread; get() copies the interned strings under the lock
// into per-thread storage hung off a pthread key (freed on thread exit, not __thread/emutls),
// so begin() can free the table while ArkUI still fills its element. The 16-argument publish
// and 17-argument getter ABI stay unchanged.
int a2BeginAt = cSource?.IndexOf("int ohos_host_accessibility_begin(int count) {", StringComparison.Ordinal) ?? -1;
int a2NodeAt = cSource?.IndexOf("int ohos_host_accessibility_node(int id,", StringComparison.Ordinal) ?? -1;
int a2CommitAt = cSource?.IndexOf("int ohos_host_accessibility_commit(void) {", StringComparison.Ordinal) ?? -1;
int a2CountAt = cSource?.IndexOf("int ohos_host_accessibility_count(void) {", StringComparison.Ordinal) ?? -1;
int a2NodeCountAt = cSource?.IndexOf("int ohos_host_accessibility_node_count(void) {", StringComparison.Ordinal) ?? -1;
int a2GetAt = cSource?.IndexOf("int ohos_host_accessibility_get(int index,", StringComparison.Ordinal) ?? -1;
int a2EndAt = a2GetAt < 0 ? -1 : cSource!.IndexOf("#ifdef __cplusplus", a2GetAt, StringComparison.Ordinal);
const string a2LockCall = "pthread_mutex_lock(&g_a11y_mutex);";
const string a2UnlockCall = "pthread_mutex_unlock(&g_a11y_mutex);";
bool a2BeginLock = LockedRegion(cSource, a2LockCall, a2UnlockCall, a2BeginAt, a2NodeAt);
bool a2NodeLock = LockedRegion(cSource, a2LockCall, a2UnlockCall, a2NodeAt, a2CommitAt);
bool a2CommitLock = LockedRegion(cSource, a2LockCall, a2UnlockCall, a2CommitAt, a2CountAt);
bool a2CountLock = LockedRegion(cSource, a2LockCall, a2UnlockCall, a2CountAt, a2NodeCountAt);
bool a2GetLock = LockedRegion(cSource, a2LockCall, a2UnlockCall, a2GetAt, a2EndAt);
int a2GetCopyAt = a2GetAt < 0 ? -1 : cSource!.IndexOf("OhosA11yCopySet* copies = OhosA11yCopySetForThread();", a2GetAt, StringComparison.Ordinal);
int a2GetUnlockAt = a2GetCopyAt < 0 ? -1 : cSource!.IndexOf(a2UnlockCall, a2GetCopyAt, StringComparison.Ordinal);
bool a2CopyKeyOk = cSource?.Contains("static pthread_key_t g_a11y_copy_key;") == true &&
    cSource.Contains("pthread_key_create(&g_a11y_copy_key, OhosA11yCopySetDestroy)") &&
    cSource.Contains("pthread_once(&g_a11y_copy_once, OhosA11yCopyKeyInit)") &&
    cSource.Contains("pthread_getspecific(g_a11y_copy_key)") &&
    cSource.Contains("pthread_setspecific(g_a11y_copy_key, set)") &&
    cSource.Contains("free(set->strings[i]);");
bool a2CopyFieldsOk = cSource?.Contains("if (role != NULL) *role = OhosA11yCopyString(copies, 0, node->role);") == true &&
    cSource.Contains("if (text != NULL) *text = OhosA11yCopyString(copies, 1, node->text);") &&
    cSource.Contains("if (description != NULL) *description = OhosA11yCopyString(copies, 2, node->description);") &&
    cSource.Contains("if (hint != NULL) *hint = OhosA11yCopyString(copies, 3, node->hint);");
bool a2CopyInsideLock = a2GetCopyAt > a2GetAt && a2GetCopyAt < a2GetUnlockAt;
bool a2SignatureOk = nativeNodeParameters.Length == 16 && nativeGetParameters.Length == 17 && headerNodeParameters.Length == 16;
bool a2Ok = a2BeginLock && a2NodeLock && a2CommitLock && a2CountLock && a2GetLock &&
    a2CopyKeyOk && a2CopyFieldsOk && a2CopyInsideLock && a2SignatureOk;
Console.WriteLine($"[verify] a2 a11y table lock begin={a2BeginLock} node={a2NodeLock} commit={a2CommitLock} count={a2CountLock} get={a2GetLock} copyKey={a2CopyKeyOk} copyUnderLock={a2CopyInsideLock} fields={a2CopyFieldsOk} signature={nativeNodeParameters.Length}/{nativeGetParameters.Length}/{headerNodeParameters.Length} assert={a2Ok}");
if (!a2Ok)
{
    throw new InvalidOperationException(
        $"the A2 a11y table lock/per-thread copy contract drifted: begin={a2BeginLock} node={a2NodeLock} " +
        $"commit={a2CommitLock} count={a2CountLock} get={a2GetLock} copyKey={a2CopyKeyOk} " +
        $"copyUnderLock={a2CopyInsideLock} fields={a2CopyFieldsOk} " +
        $"signatures={nativeNodeParameters.Length}/{nativeGetParameters.Length}/{headerNodeParameters.Length} " +
        $"source={cSourcePath ?? "<missing>"}");
}

// A5: the ArkUI_AccessibilityEventInfo created for every published event is destroyed on both
// exits of ohos_host_accessibility_send_event: the SetEventType failure path and, after the
// async send, the normal path (the provider serializes during the send; the caller keeps
// ownership), so a published event no longer leaks one info object.
int a5SendAt = s2Napi.IndexOf("OH_ArkUI_SendAccessibilityAsyncEvent(g_a11y_provider, event, nullptr);", StringComparison.Ordinal);
int a5DestroyAfterSendAt = a5SendAt < 0 ? -1 : s2Napi.IndexOf("OH_ArkUI_DestoryAccessibilityEventInfo(event);", a5SendAt, StringComparison.Ordinal);
int a5DestroyCount = CountOccurrences(s2Napi, "OH_ArkUI_DestoryAccessibilityEventInfo(event);");
bool a5SendThenDestroy = s2Napi.Contains("OH_ArkUI_SendAccessibilityAsyncEvent(g_a11y_provider, event, nullptr);\n    OH_ArkUI_DestoryAccessibilityEventInfo(event);");
bool a5FailureDestroy = s2Napi.Contains("if (OH_ArkUI_AccessibilityEventSetEventType(event, (ArkUI_AccessibilityEventType)eventType) != 0) {\n        OH_ArkUI_DestoryAccessibilityEventInfo(event);\n        return 0;\n    }");
bool a5Ok = a5SendThenDestroy && a5FailureDestroy && a5DestroyCount == 2 && a5DestroyAfterSendAt > a5SendAt;
Console.WriteLine($"[verify] a5 a11y event destroy sendThenDestroy={a5SendThenDestroy} failurePathDestroy={a5FailureDestroy} destroyCalls={a5DestroyCount} afterSend={a5DestroyAfterSendAt > a5SendAt} source='{s2NapiPath ?? "<missing>"}' assert={a5Ok}");
if (!a5Ok)
{
    throw new InvalidOperationException(
        $"the A5 accessibility event destroy contract drifted: sendThenDestroy={a5SendThenDestroy} " +
        $"failure={a5FailureDestroy} destroyCalls={a5DestroyCount} source={s2NapiPath ?? "<missing>"}");
}

// A6: lifecycle events and the NodeContent that arrive before the app handle exists are queued
// in the globals under g_context_mutex (a NULL handle is first resolved through g_app), not
// dropped; start_app transfers both queues to the new handle inside its critical section and
// register_bridge binds through OhosHostBindAndFlushBridge, which takes the lifecycle queue and
// the node content under the lock (clearing both so a return/clear cannot deliver twice) and
// runs the managed callbacks after the unlock, so a notify racing the registration cannot slip
// an event behind the flush. A registration that arrives before g_app exists is queued with the
// other pending state (g_pending_bridge_*) and bound by start_app.
int a6NotifyAt = cSource?.IndexOf("void ohos_host_notify_lifecycle(OhosHostAppHandle* handle, ohos_lifecycle_event event) {", StringComparison.Ordinal) ?? -1;
int a6NotifyLockAt = a6NotifyAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_lock(&g_context_mutex);", a6NotifyAt, StringComparison.Ordinal);
int a6NotifyQueueAt = a6NotifyLockAt < 0 ? -1 : cSource!.IndexOf("g_pending_lifecycle[g_pending_lifecycle_count++] = (int)event;", a6NotifyLockAt, StringComparison.Ordinal);
int a6NotifyUnlockAt = a6NotifyQueueAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a6NotifyQueueAt, StringComparison.Ordinal);
int a6NodeAt = cSource?.IndexOf("void ohos_host_set_node_content(OhosHostAppHandle* handle, void* node_content) {", StringComparison.Ordinal) ?? -1;
int a6NodeLockAt = a6NodeAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_lock(&g_context_mutex);", a6NodeAt, StringComparison.Ordinal);
int a6NodeQueueAt = a6NodeLockAt < 0 ? -1 : cSource!.IndexOf("g_pending_node_content = node_content;", a6NodeLockAt, StringComparison.Ordinal);
int a6NodeUnlockAt = a6NodeQueueAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a6NodeQueueAt, StringComparison.Ordinal);
int a6TransferAt = a1LockAt < 0 ? -1 : cSource!.IndexOf("handle->pending_count = g_pending_lifecycle_count;", a1LockAt, StringComparison.Ordinal);
int a6TransferClearAt = a6TransferAt < 0 ? -1 : cSource!.IndexOf("g_pending_lifecycle_count = 0;", a6TransferAt, StringComparison.Ordinal);
int a6TransferNodeAt = a6TransferClearAt < 0 ? -1 : cSource!.IndexOf("handle->node_content = g_pending_node_content;", a6TransferClearAt, StringComparison.Ordinal);
int a6TransferNodeClearAt = a6TransferNodeAt < 0 ? -1 : cSource!.IndexOf("g_pending_node_content = NULL;", a6TransferNodeAt, StringComparison.Ordinal);
int a6RegisterAt = cSource?.IndexOf("void ohos_host_register_bridge(void* lifecycle, void* node, void* surface) {", StringComparison.Ordinal) ?? -1;
int a6PendingAt = a6RegisterAt < 0 ? -1 : cSource!.IndexOf("g_pending_bridge_lifecycle = lifecycle;", a6RegisterAt, StringComparison.Ordinal);
int a6BindCallAt = a6RegisterAt < 0 ? -1 : cSource!.IndexOf("OhosHostBindAndFlushBridge(handle, lifecycle, node, surface);", a6RegisterAt, StringComparison.Ordinal);
int a6FlushAt = cSource?.IndexOf("static void OhosHostBindAndFlushBridge(OhosHostAppHandle* handle, void* lifecycle, void* node, void* surface) {", StringComparison.Ordinal) ?? -1;
int a6FlushTakeAt = a6FlushAt < 0 ? -1 : cSource!.IndexOf("pending[i] = handle->pending_lifecycle[i];", a6FlushAt, StringComparison.Ordinal);
int a6FlushClearAt = a6FlushTakeAt < 0 ? -1 : cSource!.IndexOf("handle->pending_count = 0;", a6FlushTakeAt, StringComparison.Ordinal);
int a6FlushNodeAt = a6FlushClearAt < 0 ? -1 : cSource!.IndexOf("node_content = handle->node_content;", a6FlushClearAt, StringComparison.Ordinal);
int a6FlushNodeClearAt = a6FlushNodeAt < 0 ? -1 : cSource!.IndexOf("handle->node_content = NULL;", a6FlushNodeAt, StringComparison.Ordinal);
int a6FlushUnlockAt = a6FlushNodeClearAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a6FlushNodeClearAt, StringComparison.Ordinal);
int a6FlushLoopAt = a6FlushUnlockAt < 0 ? -1 : cSource!.IndexOf("((void (*)(int))lifecycle)(pending[i]);", a6FlushUnlockAt, StringComparison.Ordinal);
int a6FlushNodeCallAt = a6FlushLoopAt < 0 ? -1 : cSource!.IndexOf("((void (*)(void*))node)(node_content);", a6FlushLoopAt, StringComparison.Ordinal);
bool a6GlobalsOk = cSource?.Contains("static int g_pending_lifecycle[OHOS_MAX_PENDING_LIFECYCLE];\nstatic int g_pending_lifecycle_count = 0;\nstatic void* g_pending_node_content = NULL;") == true &&
    cSource.Contains("static void* g_pending_bridge_lifecycle = NULL;") &&
    cSource.Contains("static void* g_pending_bridge_node = NULL;") &&
    cSource.Contains("static void* g_pending_bridge_surface = NULL;");
bool a6QueueOk = a6NotifyQueueAt > a6NotifyLockAt && a6NotifyQueueAt < a6NotifyUnlockAt &&
    a6NodeQueueAt > a6NodeLockAt && a6NodeQueueAt < a6NodeUnlockAt;
bool a6TransferOk = a6TransferAt > a1LockAt && a6TransferClearAt > a6TransferAt &&
    a6TransferNodeAt > a6TransferClearAt && a6TransferNodeClearAt > a6TransferNodeAt && a6TransferNodeClearAt < a1UnlockAt;
bool a6FlushOk = a6FlushTakeAt > a6FlushAt && a6FlushClearAt > a6FlushTakeAt &&
    a6FlushNodeAt > a6FlushClearAt && a6FlushNodeClearAt > a6FlushNodeAt &&
    a6FlushNodeClearAt < a6FlushUnlockAt && a6FlushLoopAt > a6FlushUnlockAt && a6FlushNodeCallAt > a6FlushLoopAt &&
    a6PendingAt > a6RegisterAt && a6BindCallAt > a6RegisterAt;
bool a6Ok = a6GlobalsOk && a6QueueOk && a6TransferOk && a6FlushOk;
Console.WriteLine($"[verify] a6 pending lifecycle globals={a6GlobalsOk} queuedUnderLock={a6QueueOk} transferredToHandle={a6TransferOk} flushedOnRegister={a6FlushOk} lifecycleQueue={a6NotifyQueueAt > a6NotifyLockAt} nodeContentQueue={a6NodeQueueAt > a6NodeLockAt} source='{cSourcePath ?? "<missing>"}' assert={a6Ok}");
if (!a6Ok)
{
    throw new InvalidOperationException(
        $"the A6 pending lifecycle/node-content queue contract drifted: globals={a6GlobalsOk} queue={a6QueueOk} " +
        $"transfer={a6TransferOk} flush={a6FlushOk} source={cSourcePath ?? "<missing>"}");
}

// A7a: the NAPI wrapper guard (g_launch_lock/g_launch_requested) rejects a second startApp
// before a LaunchRequest or thread is allocated; both failure paths clear the flag under the
// lock so a failed launch can be retried, while a successful one leaves g_handle set and
// rejects every later call.
string a7NapiGlobals = "std::mutex g_launch_lock;\nbool g_launch_requested = false;";
int a7StartAt = s2Napi.IndexOf("napi_value StartApp(napi_env env, napi_callback_info info) {", StringComparison.Ordinal);
int a7GuardAt = a7StartAt < 0 ? -1 : s2Napi.IndexOf("std::lock_guard<std::mutex> launch_guard(g_launch_lock);", a7StartAt, StringComparison.Ordinal);
int a7RejectAt = a7GuardAt < 0 ? -1 : s2Napi.IndexOf("if (g_launch_requested || g_handle != nullptr) {", a7GuardAt, StringComparison.Ordinal);
int a7SetAt = a7RejectAt < 0 ? -1 : s2Napi.IndexOf("g_launch_requested = true;", a7RejectAt, StringComparison.Ordinal);
int a7ThreadAt = s2Napi.IndexOf("void* LaunchThread(void* arg) {", StringComparison.Ordinal);
int a7ThreadGuardAt = a7ThreadAt < 0 ? -1 : s2Napi.IndexOf("std::lock_guard<std::mutex> launch_guard(g_launch_lock);", a7ThreadAt, StringComparison.Ordinal);
int a7ThreadFailAt = a7ThreadGuardAt < 0 ? -1 : s2Napi.IndexOf("g_launch_requested = false;   // the launch failed: a retry is allowed", a7ThreadGuardAt, StringComparison.Ordinal);
int a7HandleAt = a7ThreadAt < 0 ? -1 : s2Napi.IndexOf("g_handle = handle;", a7ThreadAt, StringComparison.Ordinal);
int a7CreateFailAt = a7SetAt < 0 ? -1 : s2Napi.IndexOf("g_launch_requested = false;   // nothing was launched: a retry is allowed", a7SetAt, StringComparison.Ordinal);
bool a7NapiOk = s2Napi.Contains(a7NapiGlobals) && a7GuardAt > a7StartAt && a7RejectAt > a7GuardAt && a7SetAt > a7RejectAt &&
    a7ThreadFailAt > a7ThreadGuardAt && a7ThreadFailAt - a7ThreadGuardAt < 200 &&
    a7ThreadFailAt < a7HandleAt && a7CreateFailAt > a7SetAt;
Console.WriteLine($"[verify] a7 napi launch guard lock={s2Napi.Contains(a7NapiGlobals)} rejectSecond={a7RejectAt > a7GuardAt && a7SetAt > a7RejectAt} launchFailedCleared={a7ThreadFailAt > a7ThreadGuardAt} createFailedCleared={a7CreateFailAt > a7SetAt} handlePublished={a7ThreadFailAt < a7HandleAt} source='{s2NapiPath ?? "<missing>"}' assert={a7NapiOk}");
if (!a7NapiOk)
{
    throw new InvalidOperationException(
        $"the A7 NAPI startApp launch guard contract drifted: lock={s2Napi.Contains(a7NapiGlobals)} " +
        $"reject={a7RejectAt > a7GuardAt} set={a7SetAt > a7RejectAt} threadClear={a7ThreadFailAt > a7ThreadGuardAt} " +
        $"createClear={a7CreateFailAt > a7SetAt} source={s2NapiPath ?? "<missing>"}");
}

// A7b: the native entry's guard (g_launch_in_progress under g_context_mutex) rejects a second
// start before anything is allocated, is set and cleared under the lock and cleared again when
// the handle is published; every failure path before that runs OhosHostEndLaunch().
int a7NativeAt = cSource?.IndexOf("int ohos_host_start_app(const char* app_dir,", StringComparison.Ordinal) ?? -1;
int a7NativeLockAt = a7NativeAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_lock(&g_context_mutex);", a7NativeAt, StringComparison.Ordinal);
int a7NativeRejectAt = a7NativeLockAt < 0 ? -1 : cSource!.IndexOf("if (g_app != NULL || g_launch_in_progress) {", a7NativeLockAt, StringComparison.Ordinal);
int a7NativeSetAt = a7NativeRejectAt < 0 ? -1 : cSource!.IndexOf("g_launch_in_progress = 1;", a7NativeRejectAt, StringComparison.Ordinal);
int a7NativeUnlockAt = a7NativeSetAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a7NativeSetAt, StringComparison.Ordinal);
int a7EndLaunchCalls = CountOccurrences(cSource, "OhosHostEndLaunch();");
bool a7NativeOk = cSource?.Contains("static int g_launch_in_progress = 0;") == true &&
    a7NativeRejectAt > a7NativeLockAt && a7NativeSetAt > a7NativeRejectAt && a7NativeUnlockAt > a7NativeSetAt &&
    cSource.Contains("g_app = handle;\n    g_launch_in_progress = 0;") &&
    cSource.Contains("static void OhosHostEndLaunch(void) {\n    pthread_mutex_lock(&g_context_mutex);\n    g_launch_in_progress = 0;") &&
    a7EndLaunchCalls == 5;
Console.WriteLine($"[verify] a7 native launch guard guard={cSource?.Contains("static int g_launch_in_progress = 0;") == true} rejectSecond={a7NativeRejectAt > a7NativeLockAt && a7NativeSetAt > a7NativeRejectAt} setUnderLock={a7NativeSetAt > a7NativeRejectAt && a7NativeUnlockAt > a7NativeSetAt} clearedOnPublish={cSource?.Contains("g_app = handle;\n    g_launch_in_progress = 0;") == true} failurePaths={a7EndLaunchCalls}/5 source='{cSourcePath ?? "<missing>"}' assert={a7NativeOk}");
if (!a7NativeOk)
{
    throw new InvalidOperationException(
        $"the A7 native start_app launch guard contract drifted: guard={cSource?.Contains("static int g_launch_in_progress = 0;") == true} " +
        $"reject={a7NativeRejectAt > a7NativeLockAt} set={a7NativeSetAt > a7NativeRejectAt} " +
        $"clearOnPublish={cSource?.Contains("g_app = handle;\n    g_launch_in_progress = 0;") == true} " +
        $"endLaunchCalls={a7EndLaunchCalls} source={cSourcePath ?? "<missing>"}");
}

// A8: both IME text paths truncate through ImeUtf8PrefixLength, which backs off over UTF-8
// continuation bytes when the buffer limit cuts a sequence (keyboard_set_text replaces the
// whole buffer, ImeAppendUtf8 appends), so the managed TextInput contract never receives half
// of a multi-byte character; the old strncpy call sites are gone.
int a8HelperAt = cSource?.IndexOf("static size_t ImeUtf8PrefixLength(const char* utf8, size_t limit) {", StringComparison.Ordinal) ?? -1;
int a8AppendAt = cSource?.IndexOf("static void ImeAppendUtf8(const char* utf8) {", StringComparison.Ordinal) ?? -1;
int a8SetAt = cSource?.IndexOf("void ohos_host_keyboard_set_text(const char* utf8) {", StringComparison.Ordinal) ?? -1;
int a8AppendTakeAt = a8AppendAt < 0 ? -1 : cSource!.IndexOf("size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1 - used);", a8AppendAt, StringComparison.Ordinal);
int a8SetTakeAt = a8SetAt < 0 ? -1 : cSource!.IndexOf("size_t take = ImeUtf8PrefixLength(utf8, sizeof(g_ime_text) - 1);", a8SetAt, StringComparison.Ordinal);
int a8HelperCalls = CountOccurrences(cSource, "ImeUtf8PrefixLength(");
bool a8HelperOk = cSource?.Contains("if (take > limit) {\n        take = limit;\n        while (take > 0 && ((unsigned char)utf8[take] & 0xC0) == 0x80) {\n            take--;\n        }\n    }") == true;
bool a8CallSitesOk = a8AppendTakeAt > a8AppendAt && a8SetTakeAt > a8SetAt && a8HelperCalls == 3 &&
    cSource is not null &&
    cSource.Contains("memcpy(g_ime_text + used, utf8, take);") && cSource.Contains("memcpy(g_ime_text, utf8, take);") &&
    cSource.Contains("g_ime_text[used + take] = '\\0';") && cSource.Contains("g_ime_text[take] = '\\0';") &&
    !cSource.Contains("strncpy(g_ime_text");
bool a8Ok = cSource != null && a8HelperAt >= 0 && a8HelperOk && a8CallSitesOk;
Console.WriteLine($"[verify] a8 ime utf8 truncation boundaryBackOff={a8HelperOk} appendCall={a8AppendTakeAt > a8AppendAt} setTextCall={a8SetTakeAt > a8SetAt} callSites={a8HelperCalls}/3 strncpyRemoved={cSource?.Contains("strncpy(g_ime_text") != true} source='{cSourcePath ?? "<missing>"}' assert={a8Ok}");
if (!a8Ok)
{
    throw new InvalidOperationException(
        $"the A8 IME UTF-8 boundary back-off contract drifted: helper={a8HelperOk} callSites={a8HelperCalls} " +
        $"append={a8AppendTakeAt > a8AppendAt} setText={a8SetTakeAt > a8SetAt} source={cSourcePath ?? "<missing>"}");
}

// B3a: the shell stamps the per-registration document id into documents it served for the
// matching origin only: injectPageBridge (called from onPageEnd) writes window.__ohHybridId /
// window.__ohBlazorId under the origin + registered + non-empty-id guards, so a document the
// shell did not stamp carries no id. All three preview templates carry the stamps.
string[] b3ShellVersions = { "1.0.0-preview.22", "1.0.0-preview.23", "1.0.0-preview.24" };
bool b3ShellMethod = true;
bool b3ShellHybridStamp = true;
bool b3ShellBlazorStamp = true;
bool b3ShellOriginGuard = true;
bool b3ShellCallSite = true;
foreach (string b3Version in b3ShellVersions)
{
    string? b3ShellPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{b3Version}/templates/ets/pages/Index.ets");
    string b3Shell = b3ShellPath is null ? string.Empty : File.ReadAllText(b3ShellPath);
    b3ShellMethod &= b3Shell.Contains("private injectPageBridge(pageUrl: string): void {");
    b3ShellHybridStamp &= b3Shell.Contains("markers += `window.__ohHybridId = ${JSON.stringify(this.hybridDocId)};`;");
    b3ShellBlazorStamp &= b3Shell.Contains("markers += `window.__ohBlazorId = ${JSON.stringify(this.blazorDocId)};`;");
    b3ShellOriginGuard &= b3Shell.Contains("if (this.hybridRegistered && this.hybridDocId.length > 0 && pageUrl.startsWith(this.hybridOrigin)) {") &&
        b3Shell.Contains("if (this.blazorRegistered && this.blazorDocId.length > 0 && pageUrl.startsWith(this.blazorOrigin)) {");
    b3ShellCallSite &= b3Shell.Contains("this.injectPageBridge(pageUrl);");
}
bool b3ShellOk = b3ShellMethod && b3ShellHybridStamp && b3ShellBlazorStamp && b3ShellOriginGuard && b3ShellCallSite;
Console.WriteLine($"[verify] b3 shell document markers packs=22,23,24 method={b3ShellMethod} hybridStamp={b3ShellHybridStamp} blazorStamp={b3ShellBlazorStamp} originGuard={b3ShellOriginGuard} onPageEnd={b3ShellCallSite} assert={b3ShellOk}");
if (!b3ShellOk)
{
    throw new InvalidOperationException(
        $"the B3 shell document-marker stamps are missing: method={b3ShellMethod} hybrid={b3ShellHybridStamp} " +
        $"blazor={b3ShellBlazorStamp} originGuard={b3ShellOriginGuard} callSite={b3ShellCallSite}");
}

// B3b: both managed handlers only deliver host -> page through a marker-checked eval: the
// script returns 'skip' unless window.__ohHybridId / window.__ohBlazorId equals the id the
// shell stamped for that registration (serialized as the eval's first argument), and a skip is
// logged instead of delivering into a document the handler did not load.
string? b3HybridPath = FindHostSource("OpenHarmonyHybridWebViewHandler.cs");
string b3Hybrid = b3HybridPath is null ? string.Empty : File.ReadAllText(b3HybridPath);
string? b3BlazorPath = FindHostSource("OpenHarmonyBlazorWebViewHandler.cs");
string b3Blazor = b3BlazorPath is null ? string.Empty : File.ReadAllText(b3BlazorPath);
bool b3HybridOk = b3Hybrid.Contains("private async Task SendRawMessageCoreAsync(string json)") &&
    b3Hybrid.Contains("\"if(window.__ohHybridId!==id){return 'skip';}\" +") &&
    b3Hybrid.Contains("JsonSerializer.Serialize(_pageId) + \",\" + json + \")\"") &&
    b3Hybrid.Contains("result is not null && result.Trim().Trim('\"') == \"skip\"") &&
    b3Hybrid.Contains("hybrid raw message skipped: the loaded document is not this handler's page");
bool b3BlazorOk = b3Blazor.Contains("protected override void SendMessage(string message)") &&
    b3Blazor.Contains("\"if(window.__ohBlazorId!==id){return 'skip';}\" +") &&
    b3Blazor.Contains("JsonSerializer.Serialize(_pageDocumentId) + \",\" + JsonSerializer.Serialize(message) + \")\"") &&
    b3Blazor.Contains("result is not null && result.Trim().Trim('\"') == \"skip\"") &&
    b3Blazor.Contains("blazor message skipped: the loaded document is not this handler's page");
bool b3MarkerChecks = b3Hybrid.Contains("if(window.__ohHybridId!==id){return 'skip';}") &&
    b3Blazor.Contains("if(window.__ohBlazorId!==id){return 'skip';}");
bool b3SkipLogs = b3Hybrid.Contains("raw message skipped") && b3Blazor.Contains("message skipped");
bool b3HandlersOk = b3HybridOk && b3BlazorOk;
Console.WriteLine($"[verify] b3 handler document markers hybrid={b3HybridOk} blazor={b3BlazorOk} markerChecked={b3MarkerChecks} skipLogged={b3SkipLogs} hybridSource='{b3HybridPath ?? "<missing>"}' blazorSource='{b3BlazorPath ?? "<missing>"}' assert={b3HandlersOk}");
if (!b3HandlersOk)
{
    throw new InvalidOperationException(
        $"the B3 per-document marker checks are missing from the handlers: hybrid={b3HybridOk} blazor={b3BlazorOk} " +
        $"markers={b3MarkerChecks} logs={b3SkipLogs} hybridSource={b3HybridPath ?? "<missing>"} " +
        $"blazorSource={b3BlazorPath ?? "<missing>"}");
}

// ---- BATCH-1 Essentials: permissions / clipboard / connectivity real bridges -------------------
// The three Essentials surfaces that used to degrade now talk to the platform through the
// established host/ArkTS bridge:
//   IPermissions.RequestAsync -> ohos_host_request_permission(permission, id) -> the shell's
//     registerPermissionSink (abilityAccessCtrl.requestPermissionsFromUser) ->
//     host.permissionResult(id, granted) -> ohos_host_permission_complete -> the managed TCS
//     (a timeout or a missing shell/host library answers Denied);
//   IClipboard -> ohos_host_clipboard_request(id, op, text) (op 0 has / 1 get / 2 set) -> the
//     shell's registerClipboardSink (@ohos.pasteboard; reads ask for READ_PASTEBOARD) ->
//     host.clipboardResult(id, rc, text); ClipboardContentChanged rides the pasteboard 'update'
//     observer -> host.notifyClipboardChanged -> ohos_host_clipboard_notify_changed;
//   IConnectivity.NetworkAccess -> ohos_host_network_access (0 unknown / 1 none / 2 local /
//     3 internet); ConnectivityChanged rides the NetworkKit observer ->
//     host.notifyNetworkAccess -> ohos_host_network_access_notify (the host re-reads the level).
// Off-device there is no libopenharmonyhost.so, so every request must fail fast (no timeout
// wait), the answers must degrade to Denied / false / null / Unknown, and the source pins must
// show the managed P/Invoke, the C/header definitions, the NAPI exports and the shell sinks in
// all three preview templates (which must stay byte-identical).
string[] b1ShellTexts = new string[b3ShellVersions.Length];
bool b1ShellIdentical = true;
for (int i = 0; i < b3ShellVersions.Length; i++)
{
    string? b1ShellPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{b3ShellVersions[i]}/templates/ets/pages/Index.ets");
    b1ShellTexts[i] = b1ShellPath is null ? string.Empty : File.ReadAllText(b1ShellPath);
    if (i > 0)
    {
        b1ShellIdentical &= b1ShellTexts[i] == b1ShellTexts[0];
    }
}
string b1Shell = b1ShellTexts[0];

// BATCH1a: IPermissions.RequestAsync off-device. The DI default is the slice implementation, the
// request reaches the host boundary and the missing host library answers Denied immediately (the
// 30 s request timeout must not be waited out).
var b1Permissions = app.Services.GetRequiredService<Microsoft.Maui.ApplicationModel.IPermissions>();
bool b1PermissionsInstalled = b1Permissions is OpenHarmonyPermissions;
var b1PermissionWatch = System.Diagnostics.Stopwatch.StartNew();
Microsoft.Maui.ApplicationModel.PermissionStatus b1Camera = Microsoft.Maui.ApplicationModel.PermissionStatus.Unknown;
Microsoft.Maui.ApplicationModel.PermissionStatus b1Microphone = Microsoft.Maui.ApplicationModel.PermissionStatus.Unknown;
bool b1PermissionThrew = false;
try
{
    b1Camera = await b1Permissions.RequestAsync<Microsoft.Maui.ApplicationModel.Permissions.Camera>();
    b1Microphone = await b1Permissions.RequestAsync<Microsoft.Maui.ApplicationModel.Permissions.Microphone>();
}
catch (Exception ex)
{
    b1PermissionThrew = true;
    Console.WriteLine($"[verify] permissions request threw {ex.GetType().Name}: {ex.Message}");
}
long b1PermissionMs = b1PermissionWatch.ElapsedMilliseconds;
bool b1PermissionFast = b1PermissionMs < (long)OpenHarmonyPermissionBridge.RequestTimeout.TotalMilliseconds / 2;
bool b1PermissionOk = b1PermissionsInstalled && !b1PermissionThrew &&
    b1Camera == Microsoft.Maui.ApplicationModel.PermissionStatus.Denied &&
    b1Microphone == Microsoft.Maui.ApplicationModel.PermissionStatus.Denied && b1PermissionFast;
Console.WriteLine($"[verify] permissions request degraded installed={b1PermissionsInstalled} camera={b1Camera} microphone={b1Microphone} elapsedMs={b1PermissionMs} fastFail={b1PermissionFast} timeoutMs={(int)OpenHarmonyPermissionBridge.RequestTimeout.TotalMilliseconds} assert={b1PermissionOk}");
if (!b1PermissionOk)
{
    throw new InvalidOperationException("the IPermissions.RequestAsync bridge did not degrade to Denied off-device");
}

// BATCH1b: the permission bridge contract (managed P/Invoke + C/header + NAPI + shell). The C
// definitions, the shared header declarations, the NAPI sink/notify names and the shell's
// registration/answer calls must all agree, so a rename or a dropped half fails here.
MethodInfo? b1PermissionRequest = typeof(OpenHarmonyPermissionBridge).GetMethod("RequestPermissionNative", BindingFlags.NonPublic | BindingFlags.Static);
MethodInfo? b1PermissionRegister = typeof(OpenHarmonyPermissionBridge).GetMethod("RegisterPermissionResultNative", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? b1PermissionRequestImport = b1PermissionRequest?.GetCustomAttribute<DllImportAttribute>();
DllImportAttribute? b1PermissionRegisterImport = b1PermissionRegister?.GetCustomAttribute<DllImportAttribute>();
bool b1PermissionManaged = b1PermissionRequestImport is not null &&
    b1PermissionRequestImport.EntryPoint == "ohos_host_request_permission" &&
    b1PermissionRequestImport.Value == "libopenharmonyhost.so" &&
    b1PermissionRequest?.GetParameters() is { Length: 2 } b1PermissionParams &&
    b1PermissionParams[0].ParameterType == typeof(string) && b1PermissionParams[1].ParameterType == typeof(int) &&
    b1PermissionRegisterImport?.EntryPoint == "ohos_host_register_permission_result";
bool b1PermissionNative = cSource?.Contains("void ohos_host_request_permission(const char* permission, int request_id)") == true &&
    cSource.Contains("static void (*g_permission_listener)(const char* permission, int request_id) = NULL;") &&
    cSource.Contains("void ohos_host_register_permission_result(void* callback)") &&
    cSource.Contains("g_app->bridge_permission_result = (void (*)(int, int))callback;") &&
    cSource.Contains("g_app->bridge_permission_result(request_id, granted != 0 ? 1 : 0);") &&
    hSource?.Contains("void ohos_host_request_permission(const char* permission, int request_id);") == true &&
    hSource.Contains("void ohos_host_register_permission_result(void* callback);") == true;
bool b1PermissionNapi = s2Napi.Contains("HostSink g_permission_sink(\"permission\", false);") &&
    s2Napi.Contains("ohos_host_permission_set_listener(OnPermissionRequest);") &&
    s2Napi.Contains("ohos_host_permission_complete(requestId, granted);") &&
    s2Napi.Contains("\"registerPermissionSink\"") && s2Napi.Contains("\"permissionResult\"");
bool b1PermissionShell = b1Shell.Contains("this.hostCall('registerPermissionSink', typeof host.registerPermissionSink === 'function'") &&
    b1Shell.Contains("host.registerPermissionSink(async (permission: string, requestId: number): Promise<void>") &&
    b1Shell.Contains("const permissions: Permissions[] = [permission as Permissions];") &&
    b1Shell.Contains("atManager.requestPermissionsFromUser(context, permissions)") &&
    b1Shell.Contains("host.permissionResult(requestId, granted ? 1 : 0);");
bool b1PermissionContract = b1PermissionManaged && b1PermissionNative && b1PermissionNapi && b1PermissionShell;
Console.WriteLine($"[verify] permissions bridge contract managed={b1PermissionManaged} native={b1PermissionNative} napi={b1PermissionNapi} shell={b1PermissionShell} source='{cSourcePath ?? "<missing>"}' assert={b1PermissionContract}");
if (!b1PermissionContract)
{
    throw new InvalidOperationException(
        $"the permission bridge contract drifted: managed={b1PermissionManaged} native={b1PermissionNative} " +
        $"napi={b1PermissionNapi} shell={b1PermissionShell}");
}

// BATCH1c: IClipboard off-device. The DI default is the slice implementation; set/get/data
// package complete without throwing, the missing host library keeps HasText false and answers
// null, and the pasteboard 'update' push (the same private callback the native host invokes)
// raises ClipboardContentChanged.
var b1Clipboard = Microsoft.Maui.ApplicationModel.DataTransfer.Clipboard.Default;
bool b1ClipboardInstalled = b1Clipboard is OpenHarmonyClipboard;
int b1ClipboardEvents = 0;
EventHandler<EventArgs> b1ClipboardHandler = (_, _) => b1ClipboardEvents++;
b1Clipboard.ClipboardContentChanged += b1ClipboardHandler;
bool b1ClipboardThrew = false;
string? b1ClipboardText = null;
bool b1ClipboardPackage = false;
var b1ClipboardWatch = System.Diagnostics.Stopwatch.StartNew();
try
{
    await b1Clipboard.SetTextAsync("batch1-clip");
    b1ClipboardText = await b1Clipboard.GetTextAsync();
    b1ClipboardPackage = b1Clipboard is OpenHarmonyClipboard b1ClipboardConcrete &&
        await b1ClipboardConcrete.GetDataPackageAsync() is not null;
}
catch (Exception ex)
{
    b1ClipboardThrew = true;
    Console.WriteLine($"[verify] clipboard calls threw {ex.GetType().Name}: {ex.Message}");
}
long b1ClipboardMs = b1ClipboardWatch.ElapsedMilliseconds;
bool b1ClipboardFast = b1ClipboardMs < (long)OpenHarmonyClipboardBridge.RequestTimeout.TotalMilliseconds / 2;
MethodInfo? b1ClipboardChangedNative = typeof(OpenHarmonyClipboardBridge).GetMethod("OnNativeClipboardChanged", BindingFlags.NonPublic | BindingFlags.Static);
bool b1ClipboardPush = false;
try
{
    b1ClipboardChangedNative?.Invoke(null, null);
    b1ClipboardPush = b1ClipboardChangedNative is not null && b1ClipboardEvents == 1;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] clipboard push threw {ex.GetType().Name}: {ex.Message}");
}
b1Clipboard.ClipboardContentChanged -= b1ClipboardHandler;
bool b1ClipboardOk = b1ClipboardInstalled && !b1ClipboardThrew && b1ClipboardText is null &&
    !b1Clipboard.HasText && !b1ClipboardPackage && b1ClipboardFast && b1ClipboardPush;
Console.WriteLine($"[verify] clipboard degraded installed={b1ClipboardInstalled} text={(b1ClipboardText is null ? "<null>" : "set")} hasText={b1Clipboard.HasText} package={b1ClipboardPackage} elapsedMs={b1ClipboardMs} fastFail={b1ClipboardFast} changedEvents={b1ClipboardEvents} assert={b1ClipboardOk}");
if (!b1ClipboardOk)
{
    throw new InvalidOperationException("the IClipboard pasteboard bridge did not degrade off-device");
}

// BATCH1d: the clipboard bridge contract (managed P/Invoke ops + C/header + NAPI + shell,
// including the pasteboard 'update' observer and the READ_PASTEBOARD request).
bool b1ClipboardOps = OpenHarmonyClipboardBridge.HasOp == 0 &&
    OpenHarmonyClipboardBridge.GetOp == 1 && OpenHarmonyClipboardBridge.SetOp == 2;
MethodInfo? b1ClipboardRequest = typeof(OpenHarmonyClipboardBridge).GetMethod("RequestNative", BindingFlags.NonPublic | BindingFlags.Static);
MethodInfo? b1ClipboardRegister = typeof(OpenHarmonyClipboardBridge).GetMethod("RegisterResultNative", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? b1ClipboardRequestImport = b1ClipboardRequest?.GetCustomAttribute<DllImportAttribute>();
DllImportAttribute? b1ClipboardRegisterImport = b1ClipboardRegister?.GetCustomAttribute<DllImportAttribute>();
bool b1ClipboardManaged = b1ClipboardOps &&
    b1ClipboardRequestImport?.EntryPoint == "ohos_host_clipboard_request" &&
    b1ClipboardRequest?.GetParameters() is { Length: 3 } b1ClipboardParams &&
    b1ClipboardParams[0].ParameterType == typeof(int) && b1ClipboardParams[1].ParameterType == typeof(int) &&
    b1ClipboardParams[2].ParameterType == typeof(string) &&
    b1ClipboardRegisterImport?.EntryPoint == "ohos_host_clipboard_register_result";
bool b1ClipboardNative = cSource?.Contains("void ohos_host_clipboard_request(int request_id, int op, const char* text)") == true &&
    cSource.Contains("static void (*g_clipboard_listener)(int request_id, int op, const char* text) = NULL;") &&
    cSource.Contains("g_app->bridge_clipboard_result = (void (*)(int, int, const char*))callback;") &&
    cSource.Contains("g_app->bridge_clipboard_changed = (void (*)(void))callback;") &&
    cSource.Contains("g_app->bridge_clipboard_changed();") &&
    hSource?.Contains("void ohos_host_clipboard_request(int request_id, int op, const char* text);") == true &&
    hSource.Contains("void ohos_host_clipboard_register_changed(void* callback);") == true;
bool b1ClipboardNapi = s2Napi.Contains("HostSink g_clipboard_sink(\"clipboard\", false);") &&
    s2Napi.Contains("ohos_host_clipboard_set_listener(OnClipboardRequest);") &&
    s2Napi.Contains("ohos_host_clipboard_complete(requestId, rc, text.c_str());") &&
    s2Napi.Contains("ohos_host_clipboard_notify_changed();") &&
    s2Napi.Contains("\"registerClipboardSink\"") && s2Napi.Contains("\"clipboardResult\"") &&
    s2Napi.Contains("\"notifyClipboardChanged\"");
bool b1ClipboardShell = b1Shell.Contains("import pasteboard from '@ohos.pasteboard';") &&
    b1Shell.Contains("this.hostCall('registerClipboardSink', typeof host.registerClipboardSink === 'function'") &&
    b1Shell.Contains("host.registerClipboardSink(async (requestId: number, op: number, text: string): Promise<void>") &&
    b1Shell.Contains("systemPasteboard.setDataSync(pasteboard.createPlainTextData(text));") &&
    b1Shell.Contains("host.clipboardResult(requestId, rc, value);") &&
    b1Shell.Contains("pasteboard.getSystemPasteboard().on('update'") &&
    b1Shell.Contains("host.notifyClipboardChanged();") &&
    b1Shell.Contains("'ohos.permission.READ_PASTEBOARD'");
bool b1ClipboardContract = b1ClipboardManaged && b1ClipboardNative && b1ClipboardNapi && b1ClipboardShell;
Console.WriteLine($"[verify] clipboard bridge contract managed={b1ClipboardManaged} native={b1ClipboardNative} napi={b1ClipboardNapi} shell={b1ClipboardShell} ops={OpenHarmonyClipboardBridge.HasOp}/{OpenHarmonyClipboardBridge.GetOp}/{OpenHarmonyClipboardBridge.SetOp} assert={b1ClipboardContract}");
if (!b1ClipboardContract)
{
    throw new InvalidOperationException(
        $"the clipboard bridge contract drifted: managed={b1ClipboardManaged} native={b1ClipboardNative} " +
        $"napi={b1ClipboardNapi} shell={b1ClipboardShell}");
}

// BATCH1e: IConnectivity off-device. The level map covers the documented 0/1/2/3 encoding and
// anything else (including the getter's -1) is Unknown; the live property stays Unknown without
// the host library; the NetworkKit push (the same private callback the native host invokes)
// raises ConnectivityChanged with the mapped level.
var b1Connectivity = Microsoft.Maui.Networking.Connectivity.Current;
bool b1ConnectivityInstalled = b1Connectivity is OpenHarmonyConnectivity;
bool b1ConnectivityMap = OpenHarmonyConnectivity.MapNetworkAccess(0) == Microsoft.Maui.Networking.NetworkAccess.Unknown &&
    OpenHarmonyConnectivity.MapNetworkAccess(1) == Microsoft.Maui.Networking.NetworkAccess.None &&
    OpenHarmonyConnectivity.MapNetworkAccess(2) == Microsoft.Maui.Networking.NetworkAccess.Local &&
    OpenHarmonyConnectivity.MapNetworkAccess(3) == Microsoft.Maui.Networking.NetworkAccess.Internet &&
    OpenHarmonyConnectivity.MapNetworkAccess(9) == Microsoft.Maui.Networking.NetworkAccess.Unknown &&
    OpenHarmonyConnectivity.MapNetworkAccess(OpenHarmonyConnectivityBridge.Unavailable) == Microsoft.Maui.Networking.NetworkAccess.Unknown;
bool b1ConnectivityRead = OpenHarmonyConnectivityBridge.ReadNetworkAccess() == OpenHarmonyConnectivityBridge.Unavailable;
Microsoft.Maui.Networking.NetworkAccess b1ConnectivitySeen = Microsoft.Maui.Networking.NetworkAccess.Unknown;
int b1ConnectivityEvents = 0;
EventHandler<Microsoft.Maui.Networking.ConnectivityChangedEventArgs> b1ConnectivityHandler = (_, e) =>
{
    b1ConnectivitySeen = e.NetworkAccess;
    b1ConnectivityEvents++;
};
b1Connectivity.ConnectivityChanged += b1ConnectivityHandler;
MethodInfo? b1NetworkNative = typeof(OpenHarmonyConnectivityBridge).GetMethod("OnNativeNetworkAccess", BindingFlags.NonPublic | BindingFlags.Static);
bool b1ConnectivityPush = false;
try
{
    b1NetworkNative?.Invoke(null, new object[] { 2 });
    b1ConnectivityPush = b1NetworkNative is not null && b1ConnectivityEvents == 1 &&
        b1ConnectivitySeen == Microsoft.Maui.Networking.NetworkAccess.Local;
}
catch (Exception ex)
{
    Console.WriteLine($"[verify] connectivity push threw {ex.GetType().Name}: {ex.Message}");
}
b1Connectivity.ConnectivityChanged -= b1ConnectivityHandler;
bool b1ConnectivityOk = b1ConnectivityInstalled && b1ConnectivityMap && b1ConnectivityRead &&
    b1Connectivity.NetworkAccess == Microsoft.Maui.Networking.NetworkAccess.Unknown && b1ConnectivityPush;
Console.WriteLine($"[verify] connectivity degraded installed={b1ConnectivityInstalled} map4={OpenHarmonyConnectivity.MapNetworkAccess(1)}/{OpenHarmonyConnectivity.MapNetworkAccess(3)} unknown9={OpenHarmonyConnectivity.MapNetworkAccess(9) == Microsoft.Maui.Networking.NetworkAccess.Unknown} readUnavailable={b1ConnectivityRead} live={b1Connectivity.NetworkAccess} changedEvents={b1ConnectivityEvents} changedAccess={b1ConnectivitySeen} assert={b1ConnectivityOk}");
if (!b1ConnectivityOk)
{
    throw new InvalidOperationException("the IConnectivity bridge did not degrade to Unknown off-device");
}

// BATCH1f: the connectivity bridge contract (managed P/Invoke + C/header + NAPI + shell) and the
// three preview templates staying byte-identical.
MethodInfo? b1NetworkRead = typeof(OpenHarmonyConnectivityBridge).GetMethod("ReadNetworkAccess", BindingFlags.NonPublic | BindingFlags.Static);
MethodInfo? b1NetworkRegister = typeof(OpenHarmonyConnectivityBridge).GetMethod("NetworkAccessRegisterNative", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? b1NetworkReadImport = typeof(OpenHarmonyConnectivityBridge).GetMethod("NetworkAccessNative", BindingFlags.NonPublic | BindingFlags.Static)?.GetCustomAttribute<DllImportAttribute>();
DllImportAttribute? b1NetworkRegisterImport = b1NetworkRegister?.GetCustomAttribute<DllImportAttribute>();
bool b1ConnectivityManaged = b1NetworkReadImport?.EntryPoint == "ohos_host_network_access" &&
    b1NetworkReadImport.Value == "libopenharmonyhost.so" &&
    b1NetworkRegisterImport?.EntryPoint == "ohos_host_network_access_register" &&
    b1NetworkRead is not null;
bool b1ConnectivityNative = cSource?.Contains("ohos_host_network_access_register(void* callback)") == true &&
    cSource.Contains("g_app->bridge_network_access = (void (*)(int))callback;") &&
    cSource.Contains("g_app->bridge_network_access(ohos_host_network_access());") &&
    hSource?.Contains("void ohos_host_network_access_register(void* callback);") == true &&
    hSource.Contains("void ohos_host_network_access_notify(void);") == true;
bool b1ConnectivityNapi = s2Napi.Contains("ohos_host_network_access_notify();") &&
    s2Napi.Contains("\"notifyNetworkAccess\"");
bool b1ConnectivityShell = b1Shell.Contains("this.subscribeNetworkChanges();") &&
    b1Shell.Contains("import type { connection } from '@kit.NetworkKit';") &&
    b1Shell.Contains("const kit = await import('@kit.NetworkKit');") &&
    b1Shell.Contains("const netConnection = kit.connection.createNetConnection();") &&
    b1Shell.Contains("netConnection.on('netCapabilitiesChange'") &&
    b1Shell.Contains("host.notifyNetworkAccess();");
bool b1ConnectivityContract = b1ConnectivityManaged && b1ConnectivityNative && b1ConnectivityNapi &&
    b1ConnectivityShell && b1ShellIdentical;
Console.WriteLine($"[verify] connectivity bridge contract managed={b1ConnectivityManaged} native={b1ConnectivityNative} napi={b1ConnectivityNapi} shell={b1ConnectivityShell} identical={b1ShellIdentical} assert={b1ConnectivityContract}");
if (!b1ConnectivityContract)
{
    throw new InvalidOperationException(
        $"the connectivity bridge contract drifted: managed={b1ConnectivityManaged} native={b1ConnectivityNative} " +
        $"napi={b1ConnectivityNapi} shell={b1ConnectivityShell} identical={b1ShellIdentical}");
}

// ---- Performance budget (bounded, deterministic, seedless) ------------------------------------
// The frame path (OpenHarmonyWindowRenderer.Render: measure/arrange, the iterative view walk, the
// accessibility shadow tree rebuild + frame diff and the surface hooks) is timed over a fixed
// ~400-node tree so an accidental O(n^2) walk, a blocking call or a per-frame allocation storm
// fails the suite. The tree shape, the frame count and the warm-up split are fixed constants (no
// Random -> identical work on every run/machine); only the wall-clock numbers vary. A warm-up pass
// primes the JIT/static caches and one blocking collection runs before the timed loop so a
// mid-loop Gen0 pause cannot dominate the maximum.
//
// Budget rationale - deliberately generous: CI runners are shared and noisy, the suite runs in
// Debug, and off-device Render still calls the absent native host once per frame (the background
// FillColor -> ClearEffects lookup, ~4 ms per failed native call on the OpenHarmony dev host,
// sub-ms on a normal CI runner). Measured on this host: ~4 ms/frame. The perf renderer is built
// through the slice's documented CanvasFactory test hook with a canvas that no-ops the one
// rasterizer call Render makes for a detached tree (FillRectangle -> Polyline); without that, a
// second failed lookup per frame would add ~1 s to the section and swamp the managed work. The
// factory is restored immediately so no other renderer picks up the substitution.
//   * average <= 20 ms - very loose in managed terms (the actual renderer work is sub-ms) and
//     wide enough for the off-device floor plus debug JIT plus a loaded dev host; a uniform
//     regression (extra walk, blocking wait, quadratic layout) has to add >14 ms/frame to trip
//     it, and no plausible runner noise makes a healthy frame path average 20 ms.
//   * max <= 250 ms - a very loose absolute ceiling that only catches a genuine hang/stall;
//     intentionally far above any plausible single-frame cost.
//   * max/average <= 100x - the relative outlier check: single frames are routinely preempted on
//     a shared runner (10-30x a sub-millisecond average), so the documented multiple is generous
//     and only catastrophic outliers fail it even where the absolute ceilings are too loose.
// The tree is intentionally detached (no handler connection): with handlers every canvas
// primitive of the ~400 nodes pays the absent-host lookup, which measured ~1.2 s per frame here
// and would swamp the managed frame path and the suite's time budget. A detached tree keeps
// Render's managed work (measure/arrange, traversal, accessibility) plus the renderer-level
// canvas calls - the same shape the deep-tree fuzz section uses. The allocation delta is
// reported for context but not asserted: it is runtime/version dependent and the frame-time
// budget is the regression signal.
const int perfWarmupFrames = 8;
const int perfFrames = 200;
const double perfAverageCeilingMs = 20.0;
const double perfMaxCeilingMs = 250.0;
const double perfMaxAverageRatio = 100.0;
var perfDefaultCanvasFactory = OpenHarmonyWindowRenderer.CanvasFactory;
OpenHarmonyWindowRenderer.CanvasFactory = () => new PerfCanvas();
var perfRenderer = new OpenHarmonyWindowRenderer();
OpenHarmonyWindowRenderer.CanvasFactory = perfDefaultCanvasFactory;
var perfWatch = System.Diagnostics.Stopwatch.StartNew();
var perfRoot = new VerticalStackLayout { Spacing = 1 };
int perfNodes = 1;   // the root layout
for (int row = 0; row < 100; row++)
{
    var perfRow = new HorizontalStackLayout { Spacing = 1 };
    for (int cell = 0; cell < 3; cell++)
    {
        perfRow.Add(new Label { Text = $"perf node {row}.{cell}", FontSize = 10 });
        perfNodes++;
    }
    perfRoot.Add(perfRow);
    perfNodes++;
}
var perfPage = new ContentPage { Content = perfRoot };
perfPage.Measure(1080, 1920);
perfPage.Arrange(new Rect(0, 0, 1080, 1920));

// Warm up the renderer/app host: the first frames pay for JIT/static initialization and the first
// layout pass; they are excluded so the measurement is steady state, not startup.
bool perfWarm = true;
for (int i = 0; i < perfWarmupFrames; i++)
{
    perfWarm &= perfRenderer.Render(perfPage, 1080, 1920);
}
GC.Collect();
GC.WaitForPendingFinalizers();
GC.Collect();

var perfTimes = new double[perfFrames];
long perfAllocBefore = GC.GetAllocatedBytesForCurrentThread();
for (int i = 0; i < perfFrames; i++)
{
    long perfStart = System.Diagnostics.Stopwatch.GetTimestamp();
    if (!perfRenderer.Render(perfPage, 1080, 1920))
    {
        perfWarm = false;
    }
    perfTimes[i] = System.Diagnostics.Stopwatch.GetElapsedTime(perfStart).TotalMilliseconds;
}
long perfAllocDelta = GC.GetAllocatedBytesForCurrentThread() - perfAllocBefore;

var perfSorted = (double[])perfTimes.Clone();
Array.Sort(perfSorted);
double perfAverage = perfTimes.Sum() / perfFrames;
double perfP50 = perfSorted[perfFrames / 2];
double perfP95 = perfSorted[Math.Min(perfFrames - 1, (int)Math.Ceiling(perfFrames * 0.95) - 1)];
double perfMax = perfSorted[^1];
double perfMaxAverage = perfMax / Math.Max(perfAverage, 1e-9);
bool perfWithinBudget = perfAverage <= perfAverageCeilingMs
    && perfMax <= perfMaxCeilingMs
    && perfMaxAverage <= perfMaxAverageRatio;
Console.WriteLine($"[verify] perf warmup={perfWarmupFrames} frames={perfFrames} nodes={perfNodes} avg={perfAverage:0.###}ms p50={perfP50:0.###}ms p95={perfP95:0.###}ms max={perfMax:0.###}ms max/avg={perfMaxAverage:0.##} allocDelta={perfAllocDelta}B alloc/frame={perfAllocDelta / (double)perfFrames:0.#}B elapsed={(int)perfWatch.ElapsedMilliseconds}ms budget=avg<={perfAverageCeilingMs:0.###}ms,max<={perfMaxCeilingMs:0.###}ms,max/avg<={perfMaxAverageRatio:0.###} warmupOk={perfWarm} within={perfWithinBudget}");
if (!perfWarm || !perfWithinBudget)
{
    throw new InvalidOperationException(
        $"the frame-path performance budget failed: avg={perfAverage:0.###}ms (limit {perfAverageCeilingMs}ms) " +
        $"max={perfMax:0.###}ms (limit {perfMaxCeilingMs}ms) max/avg={perfMaxAverage:0.##} (limit {perfMaxAverageRatio}) " +
        $"warmupOk={perfWarm} frames={perfFrames} nodes={perfNodes}");
}

// ---- Accessibility publish-path budget (skip vs republish) ------------------------------------
// The frame budget above times the whole render; this block isolates the accessibility step of a
// frame over the same fixed tree in its two shapes: repeated unchanged frames (the skip path) and
// a frame whose tree was mutated since the last publish (the republish path). The slice's Publish
// diffs the rebuilt shadow tree against the previous frame and skips all host traffic when nothing
// moved; otherwise every pass marshals the whole tree (one P/Invoke plus UTF-8 strings per node).
// This gate pins that saving so a change that reintroduces per-frame marshalling - or makes the
// skip decision pathologically expensive - fails here instead of on a device.
//
// Two numbers are collected per pass: the render step (Refresh + Publish, what a frame pays) and
// the publish pass itself (Publish alone). The publish pass is where the skip decision and the host
// boundary live; the shadow-tree rebuild is shared work and the frame budget already covers it.
//
// Off-device there is no host library: the first publish attempt fails and flips the slice's
// internal provider-availability flag, after which every pass (changed or not) returns before the
// host boundary and the two paths become indistinguishable. The harness therefore restores that
// flag through the same reflection hook the publish-contract checks use, so the republish block
// really takes the host-boundary branch (failing there exactly like the first real publish would
// off-device) while the skip block takes the "nothing moved" branch. The flag is restored to its
// previous value when the block ends, so the fuzz tail sees the same state the interaction checks
// left behind.
//
// Budget rationale - deliberately generous, same style as the frame budget: CI runners are shared,
// the suite runs in Debug, and off-device a republish pass pays one failed native lookup whose cost
// is host-dependent (~10 ms on the OpenHarmony dev host, sub-ms on a normal CI runner).
//   * skip avg <= 20 ms and max <= 250 ms (both shapes) - the same loose managed ceilings as the
//     frame budget: the rebuild, the diff and the skip decision are sub-millisecond managed work,
//     and a regression (per-frame marshalling, an allocation storm, a blocking wait) has to add far
//     more than that to trip the ceilings.
//   * republish avg <= 50 ms and max <= 500 ms (both shapes) - the republish pass additionally
//     crosses the host boundary once per pass; the ceilings leave room for the absent-host probe on
//     a loaded host while still catching a genuine hang.
//   * render republish/skip >= 1.25x and publish republish/skip >= 2x - the documented relative
//     floors: the skip path must be materially cheaper than a republish pass. Measured on CI
//     runners the render ratio is ~1.6-1.7x and the publish ratio ~3.8-3.9x; on the OpenHarmony dev
//     host they are ~10-15x and ~80x. The floors sit well below the observed values so runner noise
//     and CPU-speed differences cannot trip them.
// The tree, the mutation sequence, the pass counts and the warm-up split are fixed constants (the
// mutated text alternates between two fixed values), so every run does identical work; only the
// wall-clock numbers vary. The whole block must stay inside a 2 s wall-clock bound.
const int a11yWarmupFrames = 8;
const int a11ySkipFrames = 50;
const int a11yRepublishFrames = 50;
const double a11ySkipAverageCeilingMs = 20.0;
const double a11ySkipMaxCeilingMs = 250.0;
const double a11yRepublishAverageCeilingMs = 50.0;
const double a11yRepublishMaxCeilingMs = 500.0;
const double a11yRenderRatioFloor = 1.25;
const double a11yPublishRatioFloor = 2.0;
const double a11yElapsedCeilingMs = 2000.0;
var a11yWatch = System.Diagnostics.Stopwatch.StartNew();
FieldInfo a11yAvailability = typeof(OpenHarmonyAccessibility).GetField("_available", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyAccessibility._available was not found; the a11y perf gate needs the provider-availability hook to isolate the skip and republish paths off-device");
bool a11yAvailabilityBefore = (bool)a11yAvailability.GetValue(null)!;
void SetA11yAvailability(bool value) => a11yAvailability.SetValue(null, value);
var a11yPerfLabels = new List<Label>();
foreach (IView a11yChild in perfRoot.Children)
{
    if (a11yChild is HorizontalStackLayout a11yRow)
    {
        foreach (IView a11yCell in a11yRow.Children)
        {
            if (a11yCell is Label a11yLabel)
            {
                a11yPerfLabels.Add(a11yLabel);
            }
        }
    }
}
Label a11yMutatedLabel = a11yPerfLabels[0];
string a11yMutatedBase = a11yMutatedLabel.Text!;

static (double Average, double P50, double P95, double Max) A11yStats(double[] samples)
{
    var sorted = (double[])samples.Clone();
    Array.Sort(sorted);
    double average = samples.Sum() / samples.Length;
    double p50 = sorted[samples.Length / 2];
    double p95 = sorted[Math.Min(samples.Length - 1, (int)Math.Ceiling(samples.Length * 0.95) - 1)];
    return (average, p50, p95, sorted[^1]);
}

// A fresh shadow tree for the fixed perf page, so both blocks start from the same snapshot.
SetA11yAvailability(true);
OpenHarmonyAccessibility.Refresh(perfPage);
int a11yNodeCount = OpenHarmonyAccessibility.Nodes.Count;

// Skip path: repeated unchanged frames. Availability is restored before every pass so Publish
// takes the "nothing moved" branch; off-device the very first republish below would otherwise leave
// the provider marked unavailable and collapse the two paths into the same early return.
int a11ySkippedBefore = OpenHarmonyAccessibility.FramesSkipped;
bool a11ySkipSawWouldPublish = false;
for (int i = 0; i < a11yWarmupFrames; i++)
{
    SetA11yAvailability(true);
    OpenHarmonyAccessibility.Refresh(perfPage);
    OpenHarmonyAccessibility.Publish();
    a11ySkipSawWouldPublish |= OpenHarmonyAccessibility.WouldPublish;
}
GC.Collect();
GC.WaitForPendingFinalizers();
GC.Collect();
var a11ySkipRenderTimes = new double[a11ySkipFrames];
var a11ySkipPublishTimes = new double[a11ySkipFrames];
for (int i = 0; i < a11ySkipFrames; i++)
{
    SetA11yAvailability(true);
    long renderStart = System.Diagnostics.Stopwatch.GetTimestamp();
    OpenHarmonyAccessibility.Refresh(perfPage);
    long publishStart = System.Diagnostics.Stopwatch.GetTimestamp();
    OpenHarmonyAccessibility.Publish();
    long publishEnd = System.Diagnostics.Stopwatch.GetTimestamp();
    a11ySkipRenderTimes[i] = System.Diagnostics.Stopwatch.GetElapsedTime(renderStart, publishEnd).TotalMilliseconds;
    a11ySkipPublishTimes[i] = System.Diagnostics.Stopwatch.GetElapsedTime(publishStart, publishEnd).TotalMilliseconds;
    a11ySkipSawWouldPublish |= OpenHarmonyAccessibility.WouldPublish;
}
int a11ySkipDelta = OpenHarmonyAccessibility.FramesSkipped - a11ySkippedBefore;
var a11ySkipRender = A11yStats(a11ySkipRenderTimes);
var a11ySkipPublish = A11yStats(a11ySkipPublishTimes);

// Republish path: a mutated tree. The mutation is a tree edit (setup, outside the timed region);
// the measured step is the same Refresh + Publish pair. Alternating between two fixed texts keeps
// the change detectable on every pass without adding work inside the timed region.
int a11yRepublishSkippedBefore = OpenHarmonyAccessibility.FramesSkipped;
int a11yRepublishDetected = 0;
int a11yHostAttempts = 0;
for (int i = 0; i < a11yWarmupFrames; i++)
{
    a11yMutatedLabel.Text = a11yMutatedBase + (i % 2 == 0 ? " warm A" : " warm B");
    SetA11yAvailability(true);
    OpenHarmonyAccessibility.Refresh(perfPage);
    OpenHarmonyAccessibility.Publish();
}
GC.Collect();
GC.WaitForPendingFinalizers();
GC.Collect();
var a11yRepublishRenderTimes = new double[a11yRepublishFrames];
var a11yRepublishPublishTimes = new double[a11yRepublishFrames];
for (int i = 0; i < a11yRepublishFrames; i++)
{
    a11yMutatedLabel.Text = a11yMutatedBase + (i % 2 == 0 ? " pub A" : " pub B");
    SetA11yAvailability(true);
    long renderStart = System.Diagnostics.Stopwatch.GetTimestamp();
    OpenHarmonyAccessibility.Refresh(perfPage);
    long publishStart = System.Diagnostics.Stopwatch.GetTimestamp();
    OpenHarmonyAccessibility.Publish();
    long publishEnd = System.Diagnostics.Stopwatch.GetTimestamp();
    a11yRepublishRenderTimes[i] = System.Diagnostics.Stopwatch.GetElapsedTime(renderStart, publishEnd).TotalMilliseconds;
    a11yRepublishPublishTimes[i] = System.Diagnostics.Stopwatch.GetElapsedTime(publishStart, publishEnd).TotalMilliseconds;
    if (OpenHarmonyAccessibility.WouldPublish)
    {
        a11yRepublishDetected++;
        if (!(bool)a11yAvailability.GetValue(null)!)
        {
            a11yHostAttempts++;
        }
    }
}
int a11yRepublishSkippedDelta = OpenHarmonyAccessibility.FramesSkipped - a11yRepublishSkippedBefore;
var a11yRepublishRender = A11yStats(a11yRepublishRenderTimes);
var a11yRepublishPublish = A11yStats(a11yRepublishPublishTimes);
SetA11yAvailability(a11yAvailabilityBefore);

double a11yRenderRatio = a11yRepublishRender.Average / Math.Max(a11ySkipRender.Average, 1e-9);
double a11yPublishRatio = a11yRepublishPublish.Average / Math.Max(a11ySkipPublish.Average, 1e-9);
bool a11ySkipWithin = a11ySkipRender.Average <= a11ySkipAverageCeilingMs && a11ySkipRender.Max <= a11ySkipMaxCeilingMs
    && a11ySkipPublish.Average <= a11ySkipAverageCeilingMs && a11ySkipPublish.Max <= a11ySkipMaxCeilingMs;
bool a11yRepublishWithin = a11yRepublishRender.Average <= a11yRepublishAverageCeilingMs && a11yRepublishRender.Max <= a11yRepublishMaxCeilingMs
    && a11yRepublishPublish.Average <= a11yRepublishAverageCeilingMs && a11yRepublishPublish.Max <= a11yRepublishMaxCeilingMs;
bool a11yRatioWithin = a11yRenderRatio >= a11yRenderRatioFloor && a11yPublishRatio >= a11yPublishRatioFloor;
bool a11yElapsedWithin = a11yWatch.ElapsedMilliseconds <= a11yElapsedCeilingMs;

// Integrity: the skip passes must never have asked the host for a publish; the republish passes
// must each have detected the mutation and reached the host boundary (which off-device fails and
// on-device publishes the whole tree), without a single skip. Snapshot indexing is pinned too, so
// the publish path is measured on a well-formed tree.
bool a11yIdsOk = a11yNodeCount > 0;
for (int i = 0; i < a11yNodeCount; i++)
{
    a11yIdsOk &= OpenHarmonyAccessibility.Nodes[i].Id == i + 1;
}
bool a11yFindOk = a11yNodeCount > 0
    && OpenHarmonyAccessibility.TryFindNode(OpenHarmonyAccessibility.Nodes[^1].Id, out var a11yFound)
    && a11yFound?.Id == OpenHarmonyAccessibility.Nodes[^1].Id;
bool a11ySkipAssert = a11ySkipDelta >= a11ySkipFrames && !a11ySkipSawWouldPublish;
bool a11yRepublishAssert = a11yRepublishDetected == a11yRepublishFrames
    && a11yRepublishSkippedDelta == 0
    && (a11yHostAttempts == 0 || a11yHostAttempts == a11yRepublishFrames)
    && (OpenHarmonyAccessibility.LastPublishedCount == 0 || OpenHarmonyAccessibility.LastPublishedCount == a11yNodeCount);
bool a11yIntegrity = a11yIdsOk
    && a11yFindOk
    && a11yNodeCount == perfNodes + 1
    && a11ySkipAssert
    && a11yRepublishAssert;
bool a11yAllWithin = a11yIntegrity && a11ySkipWithin && a11yRepublishWithin && a11yRatioWithin && a11yElapsedWithin;

Console.WriteLine($"[verify] perf a11y render skip warmup={a11yWarmupFrames} repeats={a11ySkipFrames} nodes={a11yNodeCount} avg={a11ySkipRender.Average:0.###}ms p50={a11ySkipRender.P50:0.###}ms p95={a11ySkipRender.P95:0.###}ms max={a11ySkipRender.Max:0.###}ms budget=avg<={a11ySkipAverageCeilingMs:0.###}ms,max<={a11ySkipMaxCeilingMs:0.###}ms within={a11ySkipWithin}");
Console.WriteLine($"[verify] perf a11y render republish warmup={a11yWarmupFrames} repeats={a11yRepublishFrames} nodes={a11yNodeCount} avg={a11yRepublishRender.Average:0.###}ms p50={a11yRepublishRender.P50:0.###}ms p95={a11yRepublishRender.P95:0.###}ms max={a11yRepublishRender.Max:0.###}ms budget=avg<={a11yRepublishAverageCeilingMs:0.###}ms,max<={a11yRepublishMaxCeilingMs:0.###}ms within={a11yRepublishWithin}");
Console.WriteLine($"[verify] perf a11y publish skip repeats={a11ySkipFrames} avg={a11ySkipPublish.Average:0.###}ms p50={a11ySkipPublish.P50:0.###}ms p95={a11ySkipPublish.P95:0.###}ms max={a11ySkipPublish.Max:0.###}ms within={a11ySkipWithin}");
Console.WriteLine($"[verify] perf a11y publish republish repeats={a11yRepublishFrames} avg={a11yRepublishPublish.Average:0.###}ms p50={a11yRepublishPublish.P50:0.###}ms p95={a11yRepublishPublish.P95:0.###}ms max={a11yRepublishPublish.Max:0.###}ms within={a11yRepublishWithin}");
Console.WriteLine($"[verify] perf a11y ratio render={a11yRenderRatio:0.##}x floor={a11yRenderRatioFloor:0.###}x publish={a11yPublishRatio:0.##}x floor={a11yPublishRatioFloor:0.###}x assert={a11yRatioWithin}");
Console.WriteLine($"[verify] perf a11y skip decision unchanged={a11ySkipFrames} wouldPublish={a11ySkipSawWouldPublish} framesSkipped=+{a11ySkipDelta} published={OpenHarmonyAccessibility.LastPublishedCount} assert={a11ySkipAssert}");
Console.WriteLine($"[verify] perf a11y republish decision changed={a11yRepublishDetected} framesSkipped=+{a11yRepublishSkippedDelta} hostAttempts={a11yHostAttempts} published={OpenHarmonyAccessibility.LastPublishedCount} pending=0x{OpenHarmonyAccessibility.PendingEventCount:x} assert={a11yRepublishAssert}");
Console.WriteLine($"[verify] perf a11y budget elapsed={(int)a11yWatch.ElapsedMilliseconds}ms limit={(int)a11yElapsedCeilingMs}ms repeats={a11ySkipFrames + a11yRepublishFrames} warmup={a11yWarmupFrames * 2} skipWithin={a11ySkipWithin} republishWithin={a11yRepublishWithin} ratioWithin={a11yRatioWithin} elapsedWithin={a11yElapsedWithin} integrity nodes={a11yNodeCount} expected={perfNodes + 1} idsSequential={a11yIdsOk} tryFindNode={a11yFindOk} assert={a11yAllWithin}");
if (!a11yAllWithin)
{
    throw new InvalidOperationException(
        $"the accessibility publish-path performance budget failed: render skip avg={a11ySkipRender.Average:0.###}ms (limit {a11ySkipAverageCeilingMs}ms) max={a11ySkipRender.Max:0.###}ms (limit {a11ySkipMaxCeilingMs}ms) " +
        $"render republish avg={a11yRepublishRender.Average:0.###}ms (limit {a11yRepublishAverageCeilingMs}ms) max={a11yRepublishRender.Max:0.###}ms (limit {a11yRepublishMaxCeilingMs}ms) " +
        $"publish skip avg={a11ySkipPublish.Average:0.###}ms publish republish avg={a11yRepublishPublish.Average:0.###}ms " +
        $"ratio render={a11yRenderRatio:0.##} (floor {a11yRenderRatioFloor}) publish={a11yPublishRatio:0.##} (floor {a11yPublishRatioFloor}) " +
        $"integrity={a11yIntegrity} elapsed={(int)a11yWatch.ElapsedMilliseconds}ms (limit {(int)a11yElapsedCeilingMs}ms) nodes={a11yNodeCount}");
}

// ---- Deterministic fuzz (bounded, seeded) -----------------------------------------------------
// A seeded storm of touch sequences with extreme but finite (mostly out-of-bounds) coordinates,
// two very long strings through the simulated bridge payloads and a ~300-node deep view tree that
// drives the iterative accessibility/diagnostics walks. It is bounded (300 sequences, 32-48 KiB
// payloads, no big buffers), deterministic (fixed seed) and must finish in seconds, so it asserts
// "no unhandled exception, no hang" without slowing the suite down.
var fuzzWatch = System.Diagnostics.Stopwatch.StartNew();
var fuzzRandom = new Random(20260920);   // fixed seed -> identical sequences on every run
string fuzzTouchResult = "no throw";
for (int i = 0; i < 300; i++)
{
    // Every fifth sequence lands inside the 1080x1920 surface; the rest uses finite but extreme
    // coordinates (including +-float.MaxValue) that no device would ever produce.
    float x0, y0, x1, y1;
    if (i % 5 == 0)
    {
        x0 = (float)(fuzzRandom.NextDouble() * 1080);
        y0 = (float)(fuzzRandom.NextDouble() * 1920);
        x1 = (float)(fuzzRandom.NextDouble() * 1080);
        y1 = (float)(fuzzRandom.NextDouble() * 1920);
    }
    else if (i % 97 == 0)
    {
        x0 = float.MaxValue; y0 = -float.MaxValue;
        x1 = float.MinValue; y1 = float.MaxValue;
    }
    else
    {
        x0 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        y0 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        x1 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
        y1 = (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000);
    }
    try
    {
        host.HandleTouch(true, false, x0, y0);
        for (int moves = fuzzRandom.Next(3); moves > 0; moves--)
        {
            host.HandleMove((float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000),
                            (float)(fuzzRandom.NextDouble() * 4_000_000 - 2_000_000));
        }
        host.HandleTouch(false, true, x1, y1);
    }
    catch (Exception ex)
    {
        fuzzTouchResult = $"sequence {i} threw {ex.GetType().Name}: {ex.Message}";
        break;
    }
}
Console.WriteLine($"[verify] fuzz touch sequences=300 seed=20260920 extreme=finite out-of-bounds=true result={fuzzTouchResult}");
if (fuzzTouchResult != "no throw")
{
    throw new InvalidOperationException($"the seeded touch fuzz raised {fuzzTouchResult}");
}

// Two very long payloads through the simulated JS -> .NET bridge: the HybridWebView
// __RawMessage channel (escaped/unescaped) and the native notifyJsMessage callback, both must
// round-trip the full string without throwing.
string fuzzLongRaw = new string('r', 32 * 1024);
string fuzzLongJson = new string('j', 48 * 1024);
string? fuzzRawSeen = null;
string? fuzzJsSeen = null;
void FuzzOnJs(string payload) => fuzzJsSeen = payload;
hybridProbe.RawMessageReceived += (_, e) => fuzzRawSeen = e.Message;
OpenHarmonyWebViewHandler.JsMessage += FuzzOnJs;
string fuzzPayloadResult;
try
{
    OpenHarmonyHybridWebViewHandler.OnJsMessage(hybridEnvelope + "__RawMessage|" + Uri.EscapeDataString(fuzzLongRaw));
    string? fuzzRawAfterHybrid = fuzzRawSeen;
    OpenHarmonyWebViewHandler.HandleJsMessage("{\"pad\":\"" + fuzzLongJson + "\"}");
    string expectedJson = "{\"pad\":\"" + fuzzLongJson + "\"}";
    // The native WebView callback is also fanned out to the HybridWebView raw channel (the shell
    // routes every dotnetHost.postMessage payload through it), but that JSON carries no
    // document-origin envelope, so the hybrid channel now rejects it instead of broadcasting it:
    // the raw probe keeps the last accepted (enveloped) message.
    fuzzPayloadResult = fuzzRawAfterHybrid == fuzzLongRaw && fuzzJsSeen == expectedJson
        ? "round-trip ok"
        : $"hybrid={fuzzRawAfterHybrid?.Length ?? -1} js={fuzzJsSeen?.Length ?? -1} rawAfterJs={fuzzRawSeen?.Length ?? -1}";
}
catch (Exception ex)
{
    fuzzPayloadResult = $"{ex.GetType().Name}: {ex.Message}";
}
finally
{
    OpenHarmonyWebViewHandler.JsMessage -= FuzzOnJs;
}
Console.WriteLine($"[verify] fuzz bridge payloads raw={fuzzLongRaw.Length}B json={fuzzLongJson.Length}B result={fuzzPayloadResult}");
if (fuzzPayloadResult != "round-trip ok")
{
    throw new InvalidOperationException($"the long bridge payload fuzz failed: {fuzzPayloadResult}");
}

// A ~300-node deep tree (150 nested layouts, each with a label) through the iterative walks:
// OpenHarmonyAccessibility.Visit (the Stack-based shadow tree) and the diagnostics overlay walk,
// both reached through OpenHarmonyWindowRenderer.Render, plus the recursive Describe log. The tree
// is kept detached so the assertion is independent of the app page the touch fuzz left behind.
var fuzzRenderer = app.Services.GetRequiredService<OpenHarmonyWindowRenderer>();
var fuzzTree = new VerticalStackLayout { Spacing = 1 };
Microsoft.Maui.ILayout fuzzCursor = fuzzTree;
for (int i = 0; i < 150; i++)
{
    var fuzzLabel = new Label { Text = $"fuzz node {i}", FontSize = 8 };
    var fuzzNested = new VerticalStackLayout { Spacing = 1 };
    fuzzCursor.Add(fuzzLabel);
    fuzzCursor.Add(fuzzNested);
    fuzzCursor = fuzzNested;
}
string fuzzTreeResult;
try
{
    OpenHarmonyDiagnostics.Enabled = true;
    bool fuzzRendered = fuzzRenderer.Render(fuzzTree, 1080, 1920);
    OpenHarmonyDiagnostics.Enabled = false;
    int fuzzNodes = OpenHarmonyAccessibility.Nodes.Count;
    int fuzzDescribeChars = fuzzRenderer.Describe(fuzzTree).Length;
    fuzzTreeResult = fuzzRendered && fuzzNodes >= 300 && fuzzDescribeChars > 0
        ? "render=True walk ok"
        : $"render={fuzzRendered} nodes={fuzzNodes} describeChars={fuzzDescribeChars}";
}
catch (Exception ex)
{
    OpenHarmonyDiagnostics.Enabled = false;
    fuzzTreeResult = $"{ex.GetType().Name}: {ex.Message}";
}
Console.WriteLine($"[verify] fuzz deep tree nodes=301 depth=150 seed=20260920 result={fuzzTreeResult}");
if (fuzzTreeResult != "render=True walk ok")
{
    throw new InvalidOperationException($"the deep-tree fuzz failed: {fuzzTreeResult}");
}

int fuzzMillis = (int)fuzzWatch.ElapsedMilliseconds;
Console.WriteLine($"[verify] fuzz bounded elapsed={fuzzMillis}ms limit=30000ms seed=20260920 (no hang)");
if (fuzzWatch.Elapsed > TimeSpan.FromSeconds(30))
{
    throw new InvalidOperationException($"the fuzz section took {fuzzMillis} ms");
}

// Target object for the HybridWebView JS -> .NET invocation checks. The reflection invoker
// matches methods by name and deserializes each JSON parameter value into the parameter type.
sealed class VerifyHybridInvokeTarget
{
    public string Echo(string value) => "echo:" + value;
    public int Add(int a, int b) => a + b;
}

/// <summary>
/// Perf probe canvas: the off-device rasterizer is absent, so the frame-path measurement must not
/// pay a failed native lookup for the renderer-level background fill (FillRectangle -> Polyline).
/// Only that one call is overridden; the rest of the managed canvas path is unchanged.
/// </summary>
sealed class PerfCanvas : Microsoft.OpenHarmony.Maui.Graphics.OpenHarmonyCanvas
{
    public override void FillRectangle(float x, float y, float width, float height)
    {
    }
}

sealed class ProbeDrawable : Microsoft.Maui.Graphics.IDrawable
{
    public int DrawCalls { get; private set; }
    public int TouchCalls { get; private set; }

    public void Draw(Microsoft.Maui.Graphics.ICanvas canvas, Microsoft.Maui.Graphics.RectF dirtyRect)
    {
        DrawCalls++;
        canvas.FillColor = Microsoft.Maui.Graphics.Colors.Magenta;
        canvas.FillRectangle(dirtyRect);
    }

    public void StartInteraction(Microsoft.Maui.Graphics.PointF[] points) => TouchCalls++;
    public void DragInteraction(Microsoft.Maui.Graphics.PointF[] points) { }
    public void EndInteraction(Microsoft.Maui.Graphics.PointF[] points, bool isInsideBounds) { }
}

static class gestures
{
    public static ProbeDrawable? Drawable;
    public static Microsoft.Maui.SwipeDirection LastSwipe;
    public static bool SwipeViewClicked;
    public static bool SwipeViewInvoked;
    public static int RefreshRuns;
    public static bool PointerEntered;
    public static bool PointerPressed;
    public static bool PointerReleased;
    public static bool PointerExited;
    public static string PinchLog = "";
    public static int TapCount;
    public static bool PanStarted;
    public static bool PanCompleted;
    public static double PanTotalY;
    public static int DragStartingCount;
    public static int DragOverCount;
    public static int DragLeaveCount;
    public static int DropCount;
    public static int DropCompletedCount;
    public static string? LastDragOverText;
    public static string? DroppedText;
    public static string LastDropResult = "?";

    public static string DropResultOf(Microsoft.Maui.Controls.DropCompletedEventArgs args)
    {
        // DropResult is internal in the Controls contract; read it reflectively in the harness.
        var prop = typeof(Microsoft.Maui.Controls.DropCompletedEventArgs).GetProperty("DropResult",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
        return prop?.GetValue(args)?.ToString() ?? "unknown";
    }
}

class RoutedPage : ContentPage
{
    public RoutedPage()
    {
        Title = "Routed";
        Content = new Label { Text = "routed page" };
    }
}

class TestApp : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
        => new Window(new NavigationPage(BuildPage()) { Title = "Root", BarBackgroundColor = Colors.DarkSlateBlue });

    static ContentPage BuildPage()
    {
        var layout = new VerticalStackLayout { Padding = 24, Spacing = 16 };
        layout.Add(new Label { Text = "MAUI on OpenHarmony", FontSize = 40 });

        // Grid + HorizontalStackLayout exercise the layout handler.
        var grid = new Grid
        {
            ColumnDefinitions = { new ColumnDefinition(GridLength.Star), new ColumnDefinition(GridLength.Auto) },
        };
        var horizontal = new HorizontalStackLayout { Spacing = 12 };
        horizontal.Add(new Label { Text = "grid:", FontSize = 28 });
        var gridButton = new Button { Text = "grid button" };
        gridButton.Clicked += (_, _) => Console.WriteLine("[verify] grid button clicked");
        horizontal.Add(gridButton);
        grid.Add(horizontal);
        layout.Add(grid);

        var button = new Button { Text = "Tap me" };
        button.Clicked += (_, _) => Console.WriteLine("[verify] Button.Clicked fired");
        layout.Add(button);
        layout.Add(new Entry { Placeholder = "type here", FontSize = 30 });

        var image = new Image { Source = ImageSource.FromFile(Path.Combine(Path.GetTempPath(), "verify-image.png")), HeightRequest = 120 };
        layout.Add(image);

        // W22-2: value controls (all drawn by the slice).
        var checkBox = new CheckBox { IsChecked = false };
        var toggle = new Switch { IsToggled = false };
        var slider = new Slider { Minimum = 0, Maximum = 100, Value = 50, HeightRequest = 40 };
        var progress = new ProgressBar { Progress = 0.25, HeightRequest = 8 };
        var spinner = new ActivityIndicator { IsRunning = true, HeightRequest = 24 };
        slider.DragCompleted += (_, _) => Console.WriteLine($"[verify] slider DragCompleted value={slider.Value:0.#}");
        checkBox.CheckedChanged += (_, e) => Console.WriteLine($"[verify] checkbox CheckedChanged={e.Value}");
        toggle.Toggled += (_, e) => Console.WriteLine($"[verify] switch Toggled={e.Value}");
        var controls = new HorizontalStackLayout { Spacing = 12 };
        controls.Add(checkBox);
        controls.Add(toggle);
        controls.Add(slider);
        layout.Add(controls);
        layout.Add(progress);
        layout.Add(spinner);

        // W22-7: animation, picker, tabbed page.
        var fadeLabel = new Label { Text = "fade me", FontSize = 28, Opacity = 1.0 };
        layout.Add(fadeLabel);
        var pickerCtl = new Picker { Title = "choose", FontSize = 26 };
        pickerCtl.Items.Add("alpha");
        pickerCtl.Items.Add("beta");
        pickerCtl.Items.Add("gamma");
        layout.Add(pickerCtl);

        // W22-13b: grid collection view (3 columns).
        var gridCollection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 9).Select(i => $"cell {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cellLabel = new Label { FontSize = 24 };
                cellLabel.SetBinding(Label.TextProperty, ".");
                return cellLabel;
            }),
            ItemsLayout = new GridItemsLayout(3, ItemsLayoutOrientation.Vertical),
            HeightRequest = 160,
        };
        layout.Add(gridCollection);

        // W22-15: grouped collection view (headers) + carousel looping.
        var grouped = new CollectionView
        {
            ItemsSource = new List<List<string>>
            {
                new() { "g1-item A", "g1-item B" },
                new() { "g2-item A", "g2-item B" },
            },
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 22 };
                itemLabel.SetBinding(Label.TextProperty, ".");
                return itemLabel;
            }),
            GroupHeaderTemplate = new DataTemplate(() =>
            {
                var header = new Label { FontSize = 24, TextColor = Colors.Gold };
                header.SetBinding(Label.TextProperty, ".");
                return header;
            }),
            IsGrouped = true,
            HeightRequest = 200,
        };
        layout.Add(grouped);

        // W22-12: legacy ListView (cells) + CarouselView.
        var listView = new ListView
        {
            ItemsSource = Enumerable.Range(0, 12).Select(i => $"list row {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var cell = new TextCell();
                cell.SetBinding(TextCell.TextProperty, ".");
                return cell;
            }),
            HeightRequest = 200,
        };
        layout.Add(listView);

        var carousel = new CarouselView
        {
            ItemsSource = new List<string> { "slide A", "slide B", "slide C" },
            ItemTemplate = new DataTemplate(() =>
            {
                var label = new Label { FontSize = 34 };
                label.SetBinding(Label.TextProperty, ".");
                return label;
            }),
            HeightRequest = 140,
        };
        layout.Add(carousel);

        // Audit batch 2: GraphicsView / ContentView / ImageButton.
        layout.Add(new GraphicsView { Drawable = gestures.Drawable, HeightRequest = 80 });
        layout.Add(new ContentView
        {
            HeightRequest = 60,
            Content = new Label { Text = "content view", FontSize = 24 },
        });
        string buttonImagePath = Path.Combine(Path.GetTempPath(), "verify-button.png");
        File.WriteAllBytes(buttonImagePath, Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));
        layout.Add(new ImageButton { Source = ImageSource.FromFile(buttonImagePath), HeightRequest = 64 });

        // Audit batch: BoxView / IndicatorView / Frame / Editor (and a XAML page below).
        layout.Add(new BoxView { Color = Colors.Gold, HeightRequest = 18 });
        layout.Add(new IndicatorView { Count = 3, Position = 1, HeightRequest = 18 });
        layout.Add(new Frame
        {
            BorderColor = Colors.Teal,
            CornerRadius = 8,
            Content = new Label { Text = "framed", FontSize = 24 },
        });
        layout.Add(new Editor { Placeholder = "editor here", HeightRequest = 80 });

        // W22-9: async image source (stream).
        var streamImage = new Image { HeightRequest = 80 };
        streamImage.Source = ImageSource.FromStream(() => new MemoryStream(Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")));
        layout.Add(streamImage);

        // W22-8: date/time pickers.
        var datePicker = new DatePicker { Date = new DateTime(2026, 9, 17), FontSize = 26 };
        var timePicker = new TimePicker { Time = new TimeSpan(14, 30, 0), FontSize = 26 };
        layout.Add(new HorizontalStackLayout { Spacing = 16, Children = { datePicker, timePicker } });

        // Gap 1c: swipe gesture recognizer (reuses the drag tracking).
        var swipeLabel = new Label { Text = "swipe me", FontSize = 28 };
        var swipeGesture = new SwipeGestureRecognizer { Direction = SwipeDirection.Left | SwipeDirection.Right, Threshold = 30 };
        swipeGesture.Swiped += (_, e) => gestures.LastSwipe = e.Direction;
        swipeLabel.GestureRecognizers.Add(swipeGesture);
        layout.Insert(0, swipeLabel);

        // Limitations re-audit: pointer gestures (enter/press/release/exit).
        var pointerLabel = new Label { Text = "hover me", FontSize = 28 };
        var pointerGesture = new PointerGestureRecognizer();
        pointerGesture.PointerEntered += (_, _) => gestures.PointerEntered = true;
        pointerGesture.PointerPressed += (_, _) => gestures.PointerPressed = true;
        pointerGesture.PointerReleased += (_, _) => gestures.PointerReleased = true;
        pointerGesture.PointerExited += (_, _) => gestures.PointerExited = true;
        pointerLabel.GestureRecognizers.Add(pointerGesture);
        layout.Insert(1, pointerLabel);

        // Limitations re-audit: pinch gestures (shell reports phase/scale/centre).
        var pinchLabel = new Label { Text = "pinch me", FontSize = 28 };
        var pinchGesture = new PinchGestureRecognizer();
        pinchGesture.PinchUpdated += (_, e) => gestures.PinchLog += $"{e.Status}:{e.Scale:0.0} ";
        pinchLabel.GestureRecognizers.Add(pinchGesture);
        layout.Insert(2, pinchLabel);

        // Gap 1d: SwipeView with a right-hand item (revealed by a left drag).
        var swipeItem = new SwipeItem { Text = "Delete", BackgroundColor = Colors.OrangeRed };
        swipeItem.Clicked += (_, _) => gestures.SwipeViewClicked = true;
        swipeItem.Invoked += (_, _) => gestures.SwipeViewInvoked = true;
        var swipeRow = new SwipeView { HeightRequest = 120, Content = new Label { Text = "swipeable row" } };
        swipeRow.RightItems.Add(swipeItem);
        layout.Insert(1, swipeRow);

        // Gap 1d: RefreshView (pull down to refresh).
        var refreshView = new RefreshView { HeightRequest = 140, Content = new Label { Text = "pull to refresh" } };
        refreshView.Command = new Command(() => gestures.RefreshRuns++);
        layout.Insert(2, refreshView);

// W22-6: gestures + transforms.
        var tapLabel = new Label { Text = "tap me", FontSize = 28 };
        var tapGesture = new TapGestureRecognizer();
        tapGesture.Tapped += (_, _) => gestures.TapCount++;
        tapLabel.GestureRecognizers.Add(tapGesture);
        layout.Add(tapLabel);

        var panLabel = new Label { Text = "pan me", FontSize = 28 };
        var panGesture = new PanGestureRecognizer();
        panGesture.PanUpdated += (_, e) =>
        {
            if (e.StatusType == GestureStatus.Started) gestures.PanStarted = true;
            if (e.StatusType == GestureStatus.Running) gestures.PanTotalY = e.TotalY;
            if (e.StatusType == GestureStatus.Completed) gestures.PanCompleted = true;
        };
        panLabel.GestureRecognizers.Add(panGesture);
        layout.Add(panLabel);

        var animatedLabel = new Label { Text = "transformed", FontSize = 28, Opacity = 0.5, TranslationY = 12, Scale = 1.1, Rotation = 10 };
        layout.Add(animatedLabel);

        // W22-5: shapes, border, stepper, radio button, search bar.
        var shapes = new HorizontalStackLayout { Spacing = 12 };
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Rectangle { WidthRequest = 60, HeightRequest = 60, Fill = Colors.OrangeRed, Stroke = Colors.White, StrokeThickness = 2 });
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Ellipse { WidthRequest = 60, HeightRequest = 60, Fill = Colors.MediumSeaGreen });
        shapes.Add(new Microsoft.Maui.Controls.Shapes.Line { X1 = 0, Y1 = 0, X2 = 60, Y2 = 60, Stroke = Colors.Gold, StrokeThickness = 3 });
        layout.Add(shapes);

        var border = new Border
        {
            Stroke = Colors.DodgerBlue,
            StrokeThickness = 3,
            Padding = 10,
            Content = new Label { Text = "inside border", FontSize = 26 },
        };
        layout.Add(border);

        var controls2 = new HorizontalStackLayout { Spacing = 16 };
        var stepper = new Stepper { Minimum = 0, Maximum = 10, Increment = 1, Value = 1 };
        var radio = new RadioButton { Content = "radio choice", IsChecked = false };
        var search = new SearchBar { Placeholder = "search...", HeightRequest = 48 };
        controls2.Add(stepper);
        controls2.Add(radio);
        controls2.Add(search);
        layout.Add(controls2);

        // W22-4: collection view with a template (items materialized by the slice).
        var collection = new CollectionView
        {
            ItemsSource = Enumerable.Range(0, 20).Select(i => $"item {i}").ToList(),
            ItemTemplate = new DataTemplate(() =>
            {
                var itemLabel = new Label { FontSize = 26 };
                itemLabel.SetBinding(Label.TextProperty, ".");
                return itemLabel;
            }),
            HeightRequest = 300,
            SelectionMode = SelectionMode.Single,
        };
        layout.Add(collection);

        // A scroll view with more content than fits.
        var tall = new VerticalStackLayout { Spacing = 8 };
        for (int i = 0; i < 12; i++)
        {
            tall.Add(new Label { Text = $"scroll row {i}", FontSize = 26 });
        }
        layout.Add(new ScrollView { Content = tall, HeightRequest = 400 });
        return new ContentPage { Content = layout };
    }
}
