using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Hosting;
using Microsoft.Maui.Platform;

// The suite's [verify] line total is part of its contract: the CI job and scripts/preflight.sh
// gate on the floor declared here, so count the lines actually printed (see the [suite] summary
// after the fuzz tail) instead of letting every caller repeat its own threshold constant.
VerifyLineCountingWriter verifyStdout = new(Console.Out);
Console.SetOut(verifyStdout);
const int verifyCheckTotal = 324;                     // documented full [verify] line count
const int verifyCheckFloor = verifyCheckTotal - 20;   // documented floor convention (total - 20)

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
bool hybridRegistered = MauiOpenHarmonyExtensions.SliceHandlers.TryGetValue(typeof(IHybridWebView), out SliceHandlerRegistration? hybridType) &&
                        hybridType?.HandlerType == typeof(OpenHarmonyHybridWebViewHandler);
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
    s1Extensions.Contains("[typeof(Microsoft.AspNetCore.Components.WebView.Maui.IBlazorWebView)] = new(typeof(OpenHarmonyBlazorWebViewHandler))");
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

// ---- KIT-IMPL: HMS Kit platform extensions (Share Kit multi-file + Scan Kit default UI) -------
// The shell compiles these probes on the OpenHarmony SDK only because the module specifiers stay
// in variables and the resolved value is cast to a local structural interface: a literal
// import('@kit.ShareKit') is a hard ArkTS compile error there (10505001, KIT-IMPL probe a). The
// sinks register only when the runtime provides the kit, so the default OpenHarmony shell
// registers neither and the managed bridges degrade off-device (no host library) without
// throwing. These checks pin the shell probe/sink shape, the host+managed contract and that
// degradation.

// KIT1: the shell template (preview.24) carries both probes and their sinks, the call sites sit
// in aboutToAppear, and all three pack templates carry the same block.
string? kitShellPath = FindHostSource("packs/Microsoft.OpenHarmony.Sdk/1.0.0-preview.24/templates/ets/pages/Index.ets");
string kitShell = kitShellPath is null ? string.Empty : File.ReadAllText(kitShellPath);
bool kitShellShare = kitShell.Contains("const kitName: string = '@kit.ShareKit';") &&
    kitShell.Contains("const kit = (await import(kitName)) as HmsShareKit;") &&
    kitShell.Contains("host.registerShareKitSink((uris: string, title: string): boolean => {") &&
    kitShell.Contains("private dispatchShareKit(uris: string, title: string): boolean {") &&
    kitShell.Contains("fileUri.getUriFromPath(path)") &&
    kitShell.Contains("utd.UniformDataType.FILE");
bool kitShellScan = kitShell.Contains("canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')") &&
    kitShell.Contains("const kitName: string = '@kit.ScanKit';") &&
    kitShell.Contains("const kit = (await import(kitName)) as HmsScanKit;") &&
    kitShell.Contains("host.registerScanSink((requestId: number): void => {") &&
    kitShell.Contains("private async runScan(requestId: number): Promise<void> {") &&
    kitShell.Contains("host.notifyScanResult(requestId, code, value);") &&
    kitShell.Contains("scanCode === 1000500002 ? -2 : -1");
bool kitShellCallsites = kitShell.Contains("this.probeShareKit();") && kitShell.Contains("this.probeScanKit();") &&
    kitShell.Contains("Share Kit unavailable on this device:");
int kitShellPacks = 0;
string[] kitShellPackVersions = { "1.0.0-preview.22", "1.0.0-preview.23", "1.0.0-preview.24" };
foreach (string kitPackVersion in kitShellPackVersions)
{
    string? kitPackPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{kitPackVersion}/templates/ets/pages/Index.ets");
    string kitPackShell = kitPackPath is null ? string.Empty : File.ReadAllText(kitPackPath);
    kitShellPacks += kitPackShell.Contains("registerShareKitSink") && kitPackShell.Contains("registerScanSink") &&
        kitPackShell.Contains("canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')") ? 1 : 0;
}
bool kitShellOk = kitShellShare && kitShellScan && kitShellCallsites && kitShellPacks == kitShellPackVersions.Length;
Console.WriteLine($"[verify] kit1 shell probe share={kitShellShare} scan={kitShellScan} callsites={kitShellCallsites} packs={kitShellPacks}/{kitShellPackVersions.Length} assert={kitShellOk}");
if (!kitShellOk)
{
    throw new InvalidOperationException("the HMS kit shell probes/sinks are missing or drifted");
}

// KIT2: the host and managed halves: the C ABI declarations, the NAPI sink/notify names, the
// napi module table entries and the managed P/Invoke entry points + public API baseline.
string? kitHeaderPath = FindHostSource("src/OpenHarmonyHost/openharmony_host.h");
string kitHeader = kitHeaderPath is null ? string.Empty : File.ReadAllText(kitHeaderPath);
string? kitNapiPath = FindHostSource("src/OpenHarmonyHost/host_napi.cpp");
string kitNapi = kitNapiPath is null ? string.Empty : File.ReadAllText(kitNapiPath);
string? kitManagedPath = FindHostSource("OpenHarmonyHmsKits.cs");
string kitManaged = kitManagedPath is null ? string.Empty : File.ReadAllText(kitManagedPath);
string? kitLauncherPath = FindHostSource("OpenHarmonyAppLauncher.cs");
string kitLauncher = kitLauncherPath is null ? string.Empty : File.ReadAllText(kitLauncherPath);
string? kitPublicApiPath = FindHostSource("src/Core/src/PublicAPI/net-openharmony/PublicAPI.Unshipped.txt");
string kitPublicApi = kitPublicApiPath is null ? string.Empty : File.ReadAllText(kitPublicApiPath);
bool kitHostHeader = kitHeader.Contains("int ohos_host_share_kit_share(const char* uris, const char* title);") &&
    kitHeader.Contains("int ohos_host_scan_available(void);") &&
    kitHeader.Contains("int ohos_host_scan_request(int request_id);") &&
    kitHeader.Contains("void ohos_host_scan_register_result(void* callback);") &&
    kitHeader.Contains("void ohos_host_scan_result(int request_id, int code, const char* value);");
bool kitHostNapi = kitNapi.Contains("extern \"C\" int ohos_host_share_kit_share(const char* uris, const char* title)") &&
    kitNapi.Contains("HostCallJs(g_share_kit_sink, call, &handled, nullptr)") &&
    kitNapi.Contains("extern \"C\" int ohos_host_scan_available(void)") &&
    kitNapi.Contains("g_scan_sink.tsfn != nullptr") &&
    kitNapi.Contains("extern \"C\" int ohos_host_scan_request(int request_id)") &&
    kitNapi.Contains("{\"registerShareKitSink\", nullptr, RegisterShareKitSink") &&
    kitNapi.Contains("{\"registerScanSink\", nullptr, RegisterScanSink") &&
    kitNapi.Contains("{\"notifyScanResult\", nullptr, NotifyScanResult");
bool kitManagedOk = kitManaged.Contains("EntryPoint = \"ohos_host_share_kit_share\"") &&
    kitManaged.Contains("EntryPoint = \"ohos_host_scan_available\"") &&
    kitManaged.Contains("EntryPoint = \"ohos_host_scan_request\"") &&
    kitManaged.Contains("EntryPoint = \"ohos_host_scan_register_result\"") &&
    kitManaged.Contains("public static async Task<string?> ScanAsync") &&
    kitManaged.Contains("public static bool IsSupported") &&
    kitLauncher.Contains("OpenHarmonyShareKitBridge.TryShare(uris, request!.Title)") &&
    kitPublicApi.Contains("Microsoft.Maui.Platform.OpenHarmonyScan.ScanAsync(");
bool kitPinsOk = kitHostHeader && kitHostNapi && kitManagedOk;
Console.WriteLine($"[verify] kit2 bridge pins header={kitHostHeader} napi={kitHostNapi} managed={kitManagedOk} assert={kitPinsOk}");
if (!kitPinsOk)
{
    throw new InvalidOperationException("the HMS kit host/managed bridge contract drifted");
}

// KIT3: off-device degradation of the two managed bridges (no host library): the Share Kit
// dispatch answers false, ScanAsync completes with null and IsSupported answers false; all
// without throwing (the status notes are written by the bridges themselves).
bool kitShareTry = OpenHarmonyShareKitBridge.TryShare(
    new[] { "file:///data/verify-a.txt", "file:///data/verify-b.txt" }, "verify");
string? kitScanValue = await OpenHarmonyScan.ScanAsync();
bool kitScanSupported = OpenHarmonyScan.IsSupported;
bool kitDegradeOk = !kitShareTry && kitScanValue is null && !kitScanSupported;
Console.WriteLine($"[verify] kit3 degradation shareDispatch={kitShareTry} scanValue={(kitScanValue ?? "<null>")} scanSupported={kitScanSupported} assert={kitDegradeOk}");
if (!kitDegradeOk)
{
    throw new InvalidOperationException("the HMS kit bridges must degrade off-device instead of throwing");
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
bool v8ShellHostGuard = v8Shell24.Contains("typeof host !== 'undefined' && typeof host.setAppContext !== 'function'");
bool v8ShellMethodOk = v8Shell24.Contains("private publishAppContext(): void {") &&
    v8ShellHostGuard &&
    v8Shell24.Contains("} catch (contextError) {");
Console.WriteLine($"[verify] v8 shell publish method method={v8Shell24.Contains("private publishAppContext(): void {")} typeofGuard={v8ShellHostGuard} guarded={v8Shell24.Contains("} catch (contextError) {")} source='{v8ShellPath24 ?? "<missing>"}' assert={v8ShellMethodOk}");
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
        v8PackShell.Contains("typeof host !== 'undefined' && typeof host.setAppContext !== 'function'") &&
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
// A7c: the NAPI host state is per-env and JS-thread-disciplined: every binding registers an
// env cleanup hook, tears its references and threadsafe functions down with the env that
// created them, and a new env replaces (never mutates) the previous binding; every shell
// callback goes through HostCallCallback's JS-thread/env gate and the request/answer sinks
// (launcher/browser/share, flashlight, focus) answer through the HostCallJs reply instead of a
// cross-thread napi_call_function.
bool a7EnvCleanup = s2Napi.Contains("napi_add_env_cleanup_hook(env, HostEnvCleanup, slot)") &&
    s2Napi.Contains("napi_delete_reference(env, binding.exports_ref);") &&
    s2Napi.Contains("HostBindingTeardown(&g_binding_slots[i], false);") &&
    s2Napi.Contains("static napi_status HostCallCallback(napi_env env, napi_value this_arg, napi_value function,") &&
    s2Napi.Contains("if (env == nullptr || g_host->env != env || !HostIsJsThread()) {") &&
    s2Napi.Contains("static napi_status HostCallJs(HostSink& sink, SinkCall* call, bool* bool_out, int32_t* int_out)");
bool a7NapiOk = s2Napi.Contains(a7NapiGlobals) && a7GuardAt > a7StartAt && a7RejectAt > a7GuardAt && a7SetAt > a7RejectAt &&
    a7ThreadFailAt > a7ThreadGuardAt && a7ThreadFailAt - a7ThreadGuardAt < 200 &&
    a7ThreadFailAt < a7HandleAt && a7CreateFailAt > a7SetAt && a7EnvCleanup;
Console.WriteLine($"[verify] a7 napi launch guard lock={s2Napi.Contains(a7NapiGlobals)} rejectSecond={a7RejectAt > a7GuardAt && a7SetAt > a7RejectAt} launchFailedCleared={a7ThreadFailAt > a7ThreadGuardAt} createFailedCleared={a7CreateFailAt > a7SetAt} handlePublished={a7ThreadFailAt < a7HandleAt} envCleanup={a7EnvCleanup} source='{s2NapiPath ?? "<missing>"}' assert={a7NapiOk}");
if (!a7NapiOk)
{
    throw new InvalidOperationException(
        $"the A7 NAPI startApp launch guard contract drifted: lock={s2Napi.Contains(a7NapiGlobals)} " +
        $"reject={a7RejectAt > a7GuardAt} set={a7SetAt > a7RejectAt} threadClear={a7ThreadFailAt > a7ThreadGuardAt} " +
        $"createClear={a7CreateFailAt > a7SetAt} source={s2NapiPath ?? "<missing>"}");
}

// A7b: the native entry's guard (g_launch_in_progress under g_context_mutex) rejects a second
// start before anything is allocated, is set and cleared under the lock and cleared again when
// the handle is published; every failure path before that runs OhosHostEndLaunch(), including
// the payload-in-libs app_dir resolution failure, plus the NativeAOT start_app rejection when
// that path is present (six calls on the JIT-only source, seven once the AOT rejection landed;
// all before the handle publish).
int a7NativeAt = cSource?.IndexOf("int ohos_host_start_app(const char* app_dir,", StringComparison.Ordinal) ?? -1;
int a7NativeLockAt = a7NativeAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_lock(&g_context_mutex);", a7NativeAt, StringComparison.Ordinal);
int a7NativeRejectAt = a7NativeLockAt < 0 ? -1 : cSource!.IndexOf("if (g_app != NULL || g_launch_in_progress) {", a7NativeLockAt, StringComparison.Ordinal);
int a7NativeSetAt = a7NativeRejectAt < 0 ? -1 : cSource!.IndexOf("g_launch_in_progress = 1;", a7NativeRejectAt, StringComparison.Ordinal);
int a7NativeUnlockAt = a7NativeSetAt < 0 ? -1 : cSource!.IndexOf("pthread_mutex_unlock(&g_context_mutex);", a7NativeSetAt, StringComparison.Ordinal);
int a7EndLaunchCalls = CountOccurrences(cSource, "OhosHostEndLaunch();");
// The AOT rejection of a payload in start_app adds one more failure path that must release the
// launch guard; the expected count follows the source so the JIT-only and AOT-capable trees are
// both checked exactly.
bool a7AotRejection = cSource?.Contains("bridged start_app supports JIT payloads only") == true;
int a7ExpectedEndLaunchCalls = a7AotRejection ? 7 : 6;
bool a7NativeOk = cSource?.Contains("static int g_launch_in_progress = 0;") == true &&
    a7NativeRejectAt > a7NativeLockAt && a7NativeSetAt > a7NativeRejectAt && a7NativeUnlockAt > a7NativeSetAt &&
    cSource.Contains("g_app = handle;\n    g_launch_in_progress = 0;") &&
    cSource.Contains("static void OhosHostEndLaunch(void) {\n    pthread_mutex_lock(&g_context_mutex);\n    g_launch_in_progress = 0;") &&
    a7EndLaunchCalls == a7ExpectedEndLaunchCalls;
Console.WriteLine($"[verify] a7 native launch guard guard={cSource?.Contains("static int g_launch_in_progress = 0;") == true} rejectSecond={a7NativeRejectAt > a7NativeLockAt && a7NativeSetAt > a7NativeRejectAt} setUnderLock={a7NativeSetAt > a7NativeRejectAt && a7NativeUnlockAt > a7NativeSetAt} clearedOnPublish={cSource?.Contains("g_app = handle;\n    g_launch_in_progress = 0;") == true} failurePaths={a7EndLaunchCalls}/{a7ExpectedEndLaunchCalls} source='{cSourcePath ?? "<missing>"}' assert={a7NativeOk}");
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
    b3Hybrid.Contains("JsonSerializer.Serialize(_pageId, OpenHarmonySliceJsonContext.Default.String) + \",\" + json + \")\"") &&
    b3Hybrid.Contains("result is not null && result.Trim().Trim('\"') == \"skip\"") &&
    b3Hybrid.Contains("hybrid raw message skipped: the loaded document is not this handler's page");
bool b3BlazorOk = b3Blazor.Contains("protected override void SendMessage(string message)") &&
    b3Blazor.Contains("\"if(window.__ohBlazorId!==id){return 'skip';}\" +") &&
    b3Blazor.Contains("JsonSerializer.Serialize(_pageDocumentId, OpenHarmonySliceJsonContext.Default.String) + \",\" + JsonSerializer.Serialize(message, OpenHarmonySliceJsonContext.Default.String) + \")\"") &&
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
bool b1PermissionNapi = s2Napi.Contains("HostSink permission{\"permission\", false};") &&
    s2Napi.Contains("ohos_host_permission_set_listener(OnPermissionRequest);") &&
    s2Napi.Contains("ohos_host_permission_complete(requestId, granted);") &&
    s2Napi.Contains("\"registerPermissionSink\"") && s2Napi.Contains("\"permissionResult\"");
bool b1PermissionShell = b1Shell.Contains("this.hostCall('registerPermissionSink', typeof host !== 'undefined' && typeof host.registerPermissionSink === 'function'") &&
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
bool b1ClipboardNapi = s2Napi.Contains("HostSink clipboard{\"clipboard\", false};") &&
    s2Napi.Contains("ohos_host_clipboard_set_listener(OnClipboardRequest);") &&
    s2Napi.Contains("ohos_host_clipboard_complete(requestId, rc, text.c_str());") &&
    s2Napi.Contains("ohos_host_clipboard_notify_changed();") &&
    s2Napi.Contains("\"registerClipboardSink\"") && s2Napi.Contains("\"clipboardResult\"") &&
    s2Napi.Contains("\"notifyClipboardChanged\"");
bool b1ClipboardShell = b1Shell.Contains("import pasteboard from '@ohos.pasteboard';") &&
    b1Shell.Contains("this.hostCall('registerClipboardSink', typeof host !== 'undefined' && typeof host.registerClipboardSink === 'function'") &&
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

// ---- BATCH-2 Essentials: email/SMS/dialer, screenshot and geocoding ---------------------------
// The second Essentials batch adds five surfaces:
//   IEmail/Sms/PhoneDialer ride the existing startAbility bridge (kind 0 open URI) with
//     mailto:/sms:/tel: URIs; the mailto builder mirrors the shared EmailImplementation output;
//   IScreenshot asks the host for ohos_host_screenshot(out_path) (the shell snapshots the main
//     window and packs a PNG to the path asynchronously; the managed side polls for a complete
//     PNG, reads it, deletes the temp file and returns an in-memory result);
//   IGeocoding sends ohos_host_geocode_request(op, arg, id) (op 0 address -> locations with a
//     {"description":...} JSON arg, op 1 location -> placemarks with "lat,lon"), the shell
//     answers host.geocodeResult(id, rc, json) with a JSON GeoAddress array, and the managed
//     parser maps it into Placemark/Location (timeouts answer empty, like the permission deny).
// Off-device there is no libopenharmonyhost.so, so the defaults must be the slice
// implementations, every call must degrade fast (no 30 s/15 s/5 s timeout wait) and the source
// pins must show the managed P/Invokes, the C/header definitions, the NAPI exports/sinks and the
// shell call sites in all three preview templates (which must stay byte-identical).
var b2Email = Microsoft.Maui.ApplicationModel.Communication.Email.Default;
var b2Sms = Microsoft.Maui.ApplicationModel.Communication.Sms.Default;
var b2Dialer = Microsoft.Maui.ApplicationModel.Communication.PhoneDialer.Default;
var b2Screenshot = Microsoft.Maui.Media.Screenshot.Default;
var b2Geocoding = Microsoft.Maui.Devices.Sensors.Geocoding.Default;
bool b2DefaultsOk = b2Email is OpenHarmonyEmail && b2Sms is OpenHarmonySms &&
    b2Dialer is OpenHarmonyPhoneDialer && b2Screenshot is OpenHarmonyScreenshot &&
    b2Geocoding is OpenHarmonyGeocoding;
Console.WriteLine($"[verify] batch2 defaults email={b2Email.GetType().Name} sms={b2Sms.GetType().Name} dialer={b2Dialer.GetType().Name} screenshot={b2Screenshot.GetType().Name} geocoding={b2Geocoding.GetType().Name} assert={b2DefaultsOk}");
if (!b2DefaultsOk)
{
    throw new InvalidOperationException("the BATCH-2 Essentials defaults were not installed from DI");
}

// BATCH2a: the URI builders. The mailto shape is byte-for-byte what the shipped shared
// EmailImplementation.GetMailToUri produces (probed against Microsoft.Maui.Essentials rc.1:
// to/cc/bcc/subject/body order, every value Uri.EscapeDataString'd, the "?" kept for an empty
// message); the sms shape is recipients-then-body; the dialer validates like MAUI (null/empty/
// whitespace -> ArgumentNullException) and only then builds tel:.
var b2MailMessage = new Microsoft.Maui.ApplicationModel.Communication.EmailMessage
{
    Subject = "Hi there",
    Body = "Hello & <world>",
    To = new() { "a@b.c" },
    Cc = new() { "c@c.c" },
    Bcc = new() { "b@b.b" },
};
string b2Mailto = OpenHarmonyEmail.BuildMailToUri(b2MailMessage);
string b2MailtoNull = OpenHarmonyEmail.BuildMailToUri(null);
var b2SmsMessage = new Microsoft.Maui.ApplicationModel.Communication.SmsMessage
{
    Body = "ping & pong",
    Recipients = new() { "+15550001", "+15550002" },
};
string b2SmsUri = OpenHarmonySms.BuildSmsUri(b2SmsMessage);
string b2SmsUriNull = OpenHarmonySms.BuildSmsUri(null);
bool b2UrisOk = b2Mailto == "mailto:?to=a%40b.c&cc=c%40c.c&bcc=b%40b.b&subject=Hi%20there&body=Hello%20%26%20%3Cworld%3E" &&
    b2MailtoNull == "mailto:?" &&
    b2SmsUri == "sms:+15550001,+15550002?body=ping%20%26%20pong" && b2SmsUriNull == "sms:";
Console.WriteLine($"[verify] batch2 communication uris mailto='{b2Mailto}' mailtoNull='{b2MailtoNull}' sms='{b2SmsUri}' smsNull='{b2SmsUriNull}' assert={b2UrisOk}");
if (!b2UrisOk)
{
    throw new InvalidOperationException("the BATCH-2 communication URI builders drifted");
}

// BATCH2b: the off-device communication behaviour. Every Is*Supported probe is false without
// the host library; ComposeAsync completes without throwing (and the attachment drop is logged
// because one viewData Want cannot carry a file with the mailto compose); the dialer throws
// ArgumentNullException for a null number (MAUI validation) but not for a real one, which is
// logged as undispatched instead.
string b2StatusDir = Path.Combine(Path.GetTempPath(), "verify-batch2-status");
Directory.CreateDirectory(b2StatusDir);
SetBridgeContext(new Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext { FilesDir = b2StatusDir });
string b2StatusPath = Path.Combine(b2StatusDir, "dotnet-status.txt");
File.Delete(b2StatusPath);
bool b2CommSupported = b2Email.IsComposeSupported;
b2CommSupported |= b2Sms.IsComposeSupported;
b2CommSupported |= b2Dialer.IsSupported;
bool b2CommThrew = false;
bool b2DialerNullThrew = false;
bool b2DialerOpenThrew = false;
var b2CommWatch = System.Diagnostics.Stopwatch.StartNew();
try
{
    await b2Email.ComposeAsync(new Microsoft.Maui.ApplicationModel.Communication.EmailMessage
    {
        Subject = "s",
        Body = "b",
        To = new() { "a@b.c" },
        Attachments = new() { new Microsoft.Maui.ApplicationModel.Communication.EmailAttachment("/tmp/verify-batch2-attach.png") },
    });
    await b2Sms.ComposeAsync(b2SmsMessage);
    try
    {
        b2Dialer.Open("+15550001");
    }
    catch (Exception)
    {
        b2DialerOpenThrew = true;
    }
    try
    {
        b2Dialer.Open(null!);
    }
    catch (ArgumentNullException)
    {
        b2DialerNullThrew = true;
    }
}
catch (Exception ex)
{
    b2CommThrew = true;
    Console.WriteLine($"[verify] batch2 communication threw {ex.GetType().Name}: {ex.Message}");
}
long b2CommMs = b2CommWatch.ElapsedMilliseconds;
string b2StatusLog = File.Exists(b2StatusPath) ? File.ReadAllText(b2StatusPath) : string.Empty;
SetBridgeContext(savedBridgeContext);
bool b2CommFast = b2CommMs < 2000;
bool b2CommOk = !b2CommThrew && !b2CommSupported && !b2DialerOpenThrew && b2DialerNullThrew &&
    b2CommFast && b2StatusLog.Contains("attachment");
Console.WriteLine($"[verify] batch2 communication degraded supported={b2CommSupported} composeNoThrow={!b2CommThrew} dialerNullThrows={b2DialerNullThrew} dialerNumberNoThrow={!b2DialerOpenThrew} attachmentDropped={b2StatusLog.Contains("attachment")} elapsedMs={b2CommMs} fastFail={b2CommFast} assert={b2CommOk}");
if (!b2CommOk)
{
    throw new InvalidOperationException("the BATCH-2 email/SMS/dialer degradation assertion failed");
}

// BATCH2c: IScreenshot off-device. IsCaptureSupported is a NativeLibrary.TryGetExport probe
// (false without the host library) and CaptureAsync answers null immediately; the 5 s
// asynchronous-write window must not be waited out and no temp PNG may be left behind.
bool b2ShotSupported = b2Screenshot.IsCaptureSupported;
int b2ShotTempBefore = Directory.GetFiles(Path.GetTempPath(), "maui-ohos-screenshot-*.png").Length;
bool b2ShotThrew = false;
Microsoft.Maui.Media.IScreenshotResult? b2ShotResult = null;
var b2ShotWatch = System.Diagnostics.Stopwatch.StartNew();
try
{
    b2ShotResult = await b2Screenshot.CaptureAsync();
}
catch (Exception ex)
{
    b2ShotThrew = true;
    Console.WriteLine($"[verify] batch2 screenshot threw {ex.GetType().Name}: {ex.Message}");
}
long b2ShotMs = b2ShotWatch.ElapsedMilliseconds;
int b2ShotTempAfter = Directory.GetFiles(Path.GetTempPath(), "maui-ohos-screenshot-*.png").Length;
bool b2ShotFast = b2ShotMs < (long)OpenHarmonyScreenshot.CaptureTimeout.TotalMilliseconds / 2;
bool b2ShotOk = !b2ShotSupported && !b2ShotThrew && b2ShotResult is null && b2ShotFast &&
    b2ShotTempAfter == b2ShotTempBefore;
Console.WriteLine($"[verify] batch2 screenshot degraded supported={b2ShotSupported} result={(b2ShotResult is null ? "<null>" : "captured")} noThrow={!b2ShotThrew} elapsedMs={b2ShotMs} fastFail={b2ShotFast} tempFilesBefore={b2ShotTempBefore} tempFilesAfter={b2ShotTempAfter} assert={b2ShotOk}");
if (!b2ShotOk)
{
    throw new InvalidOperationException("the IScreenshot bridge did not degrade off-device");
}

// BATCH2d: the screenshot result and PNG helpers. The harness's own 1x1 PNG (the file the Image
// handler checks use) sizes through the IHDR reader, a complete file passes TryReadCompletePng
// while the same file without its trailing IEND chunk does not, Width/Height come from the IHDR,
// and OpenReadAsync/CopyToAsync round-trip the exact bytes. A Jpeg request returns the same PNG
// (the documented no-transcoder fallback) rather than throwing.
byte[] b2Png = File.ReadAllBytes(imagePath);
(int b2PngWidth, int b2PngHeight) = OpenHarmonyScreenshot.ReadPngSize(b2Png);
string b2PngPath = Path.Combine(Path.GetTempPath(), "verify-batch2-shot.png");
File.WriteAllBytes(b2PngPath, b2Png);
byte[]? b2CompletePng = OpenHarmonyScreenshot.TryReadCompletePng(b2PngPath);
File.WriteAllBytes(b2PngPath, b2Png[..^12]);
byte[]? b2TruncatedPng = OpenHarmonyScreenshot.TryReadCompletePng(b2PngPath);
File.Delete(b2PngPath);
var b2Result = new OpenHarmonyScreenshotResult(b2Png, b2PngWidth, b2PngHeight);
using Stream b2ResultStream = await b2Result.OpenReadAsync(Microsoft.Maui.Media.ScreenshotFormat.Png);
byte[] b2ReadBack = new byte[b2ResultStream.Length];
await b2ResultStream.ReadAsync(b2ReadBack);
using var b2CopyStream = new MemoryStream();
await b2Result.CopyToAsync(b2CopyStream, Microsoft.Maui.Media.ScreenshotFormat.Jpeg, 42);
using Stream b2JpegStream = await b2Result.OpenReadAsync(Microsoft.Maui.Media.ScreenshotFormat.Jpeg, 42);
bool b2ShotResultOk = b2PngWidth == 1 && b2PngHeight == 1 && b2CompletePng is not null &&
    b2TruncatedPng is null && b2Result.Width == 1 && b2Result.Height == 1 &&
    b2ReadBack.SequenceEqual(b2Png) && b2CopyStream.ToArray().SequenceEqual(b2Png) &&
    b2JpegStream.Length == b2Png.Length;
Console.WriteLine($"[verify] batch2 screenshot result png={b2PngWidth}x{b2PngHeight} complete={b2CompletePng is not null} truncatedRejected={b2TruncatedPng is null} widthHeight={b2Result.Width}x{b2Result.Height} readBack={b2ReadBack.SequenceEqual(b2Png)} copy={b2CopyStream.ToArray().SequenceEqual(b2Png)} jpegFallbackPng={b2JpegStream.Length == b2Png.Length} assert={b2ShotResultOk}");
if (!b2ShotResultOk)
{
    throw new InvalidOperationException("the screenshot result/PNG helper contract drifted");
}

// BATCH2e: IGeocoding off-device. Both calls answer an empty result immediately (the native
// request fails before the 15 s timeout) and the op/arg contract is pinned: op 0 is
// address -> location with the {"description":...} JSON object the shell parses, op 1 is
// location -> address with "lat,lon"; the escaped forward arg must survive a hostile address.
var b2GeoWatch = System.Diagnostics.Stopwatch.StartNew();
IEnumerable<Microsoft.Maui.Devices.Sensors.Placemark> b2GeoPlacemarks = Array.Empty<Microsoft.Maui.Devices.Sensors.Placemark>();
IEnumerable<Microsoft.Maui.Devices.Sensors.Location> b2GeoLocations = Array.Empty<Microsoft.Maui.Devices.Sensors.Location>();
bool b2GeoThrew = false;
try
{
    b2GeoPlacemarks = await b2Geocoding.GetPlacemarksAsync(37.5, -122.25);
    b2GeoLocations = await b2Geocoding.GetLocationsAsync("1 Microsoft Way");
}
catch (Exception ex)
{
    b2GeoThrew = true;
    Console.WriteLine($"[verify] batch2 geocoding threw {ex.GetType().Name}: {ex.Message}");
}
long b2GeoMs = b2GeoWatch.ElapsedMilliseconds;
bool b2GeoFast = b2GeoMs < (long)OpenHarmonyGeocodingBridge.RequestTimeout.TotalMilliseconds / 2;
bool b2GeoArgsOk = OpenHarmonyGeocodingBridge.ForwardOp == 0 && OpenHarmonyGeocodingBridge.ReverseOp == 1 &&
    OpenHarmonyGeocoding.BuildReverseArg(37.5, -122.25) == "37.5,-122.25";
if (b2GeoArgsOk)
{
    // The forward arg must survive a hostile address: parse it back and compare the description
    // (the encoder's escaping flavor is not pinned, only that the envelope stays one JSON object).
    using JsonDocument b2ForwardDoc = JsonDocument.Parse(OpenHarmonyGeocoding.BuildForwardArg("A \"quoted\" \\ address"));
    b2GeoArgsOk &= b2ForwardDoc.RootElement.ValueKind == JsonValueKind.Object &&
        b2ForwardDoc.RootElement.GetProperty("description").GetString() == "A \"quoted\" \\ address";
}
bool b2GeoOk = !b2GeoThrew && !b2GeoPlacemarks.Any() && !b2GeoLocations.Any() && b2GeoFast && b2GeoArgsOk;
Console.WriteLine($"[verify] batch2 geocoding degraded placemarks={b2GeoPlacemarks.Count()} locations={b2GeoLocations.Count()} noThrow={!b2GeoThrew} elapsedMs={b2GeoMs} fastFail={b2GeoFast} ops={OpenHarmonyGeocodingBridge.ForwardOp}/{OpenHarmonyGeocodingBridge.ReverseOp} args={b2GeoArgsOk} assert={b2GeoOk}");
if (!b2GeoOk)
{
    throw new InvalidOperationException("the IGeocoding bridge did not degrade off-device");
}

// BATCH2f: the GeoAddress JSON -> MAUI model parser. A realistic @ohos.geoLocationManager
// GeoAddress array maps every placemark field (placeName -> FeatureName, administrativeArea ->
// AdminArea, subAdministrativeArea -> SubAdminArea, streetNumber -> SubThoroughfare, ...); a
// locations envelope with nested coordinates and numeric strings maps Location (altitude /
// accuracy included); malformed, truncated and coordinate-less payloads answer empty.
string b2GeoJson = "[{\"latitude\":47.6399,\"longitude\":-122.1286,\"locale\":\"en-US\",\"placeName\":\"One Microsoft Way\",\"countryCode\":\"US\",\"countryName\":\"United States\",\"administrativeArea\":\"Washington\",\"subAdministrativeArea\":\"King County\",\"locality\":\"Redmond\",\"subLocality\":\"Overlake\",\"thoroughfare\":\"One Microsoft Way\",\"streetNumber\":\"1\",\"postalCode\":\"98052\"}]";
IReadOnlyList<Microsoft.Maui.Devices.Sensors.Placemark> b2ParsedPlacemarks = OpenHarmonyGeocoding.ParsePlacemarks(b2GeoJson);
Microsoft.Maui.Devices.Sensors.Placemark? b2Placemark = b2ParsedPlacemarks.FirstOrDefault();
bool b2PlacemarkOk = b2ParsedPlacemarks.Count == 1 && b2Placemark is not null &&
    b2Placemark.FeatureName == "One Microsoft Way" && b2Placemark.CountryCode == "US" &&
    b2Placemark.CountryName == "United States" && b2Placemark.AdminArea == "Washington" &&
    b2Placemark.SubAdminArea == "King County" && b2Placemark.Locality == "Redmond" &&
    b2Placemark.SubLocality == "Overlake" && b2Placemark.Thoroughfare == "One Microsoft Way" &&
    b2Placemark.SubThoroughfare == "1" && b2Placemark.PostalCode == "98052" &&
    b2Placemark.Location is { Latitude: 47.6399, Longitude: -122.1286 };
IReadOnlyList<Microsoft.Maui.Devices.Sensors.Location> b2ParsedLocations = OpenHarmonyGeocoding.ParseLocations(
    "{\"locations\":[{\"coordinates\":{\"latitude\":\"47.6\",\"longitude\":-122.3,\"altitude\":12.5,\"accuracy\":8}},{\"lat\":1.5,\"lon\":2.5}]}");
Microsoft.Maui.Devices.Sensors.Location? b2Location = b2ParsedLocations.FirstOrDefault();
bool b2LocationsOk = b2ParsedLocations.Count == 2 && b2Location is { Latitude: 47.6, Longitude: -122.3, Altitude: 12.5, Accuracy: 8 } &&
    b2ParsedLocations[1] is { Latitude: 1.5, Longitude: 2.5, Altitude: null } &&
    OpenHarmonyGeocoding.ParseLocations("[{\"lat\":1.5,\"lon\":2.5}]").Count == 1;
bool b2GeoMalformedOk = OpenHarmonyGeocoding.ParsePlacemarks("{not json").Count == 0 &&
    OpenHarmonyGeocoding.ParsePlacemarks("{\"placemarks\":[{\"latitude\":1}]}").Count == 0 &&
    OpenHarmonyGeocoding.ParseLocations(string.Empty).Count == 0;
bool b2GeoParseOk = b2PlacemarkOk && b2LocationsOk && b2GeoMalformedOk;
Console.WriteLine($"[verify] batch2 geocoding parse placemark={b2PlacemarkOk} locations={b2LocationsOk} malformed={b2GeoMalformedOk} assert={b2GeoParseOk}");
if (!b2GeoParseOk)
{
    throw new InvalidOperationException("the geocoding JSON parser drifted");
}

// BATCH2g: the registration consolidation reported by the earlier batches. The ImageButton
// handler landed as a file; this pass adds its SliceHandlers entry (the concrete control type,
// like BoxView/Frame), so both the handler table and the connector resolve it and a real
// ImageButton gets the slice handler. SemanticScreenReader installs itself through its
// ModuleInitializer (verified, no registration added); the window handler was already
// registered (verified too).
bool b2ImageButtonRegistered = MauiOpenHarmonyExtensions.SliceHandlers.TryGetValue(
        typeof(Microsoft.Maui.Controls.ImageButton), out SliceHandlerRegistration? b2ImageButtonType) &&
    b2ImageButtonType?.HandlerType == typeof(OpenHarmonyImageButtonHandler) &&
    OpenHarmonyHandlerConnector.FindSliceHandlerType(typeof(Microsoft.Maui.Controls.ImageButton)) == typeof(OpenHarmonyImageButtonHandler);
var b2ImageButton = new Microsoft.Maui.Controls.ImageButton { HeightRequest = 40, WidthRequest = 40 };
OpenHarmonyHandlerConnector.Connect(b2ImageButton);
bool b2ImageButtonConnected = b2ImageButton.Handler is OpenHarmonyImageButtonHandler;
Console.WriteLine($"[verify] batch2 registration imageButton table={b2ImageButtonRegistered} handler={(b2ImageButton.Handler?.GetType().Name ?? "<null>")} assert={b2ImageButtonRegistered && b2ImageButtonConnected}");
if (!(b2ImageButtonRegistered && b2ImageButtonConnected))
{
    throw new InvalidOperationException("the ImageButton handler registration is missing");
}

// BATCH2h: the self-installing SemanticScreenReader default (no registration was added) and the
// window handler registration + title mapper (the window was already registered; the title is
// recorded because the shell-side setter lands separately). This is the optional window pin.
bool b2ScreenReaderOk = OpenHarmonySemanticScreenReader.IsInstalled &&
    Microsoft.Maui.Accessibility.SemanticScreenReader.Default is OpenHarmonySemanticScreenReader;
bool b2WindowRegistered = MauiOpenHarmonyExtensions.SliceHandlers.TryGetValue(typeof(IWindow), out SliceHandlerRegistration? b2WindowType) &&
    b2WindowType?.HandlerType == typeof(OpenHarmonyWindowHandler) &&
    OpenHarmonyHandlerConnector.FindSliceHandlerType(typeof(IWindow)) == typeof(OpenHarmonyWindowHandler);
bool b2WindowMapperKey = OpenHarmonyWindowHandler.Mapper is Microsoft.Maui.IPropertyMapper b2WindowMapper &&
    b2WindowMapper.GetKeys().Contains(nameof(IWindow.Title));
var b2WindowProbe = new Microsoft.Maui.Controls.Window { Title = "ohos-verify-title" };
OpenHarmonyHandlerConnector.Connect(b2WindowProbe);
var b2WindowProbeHandler = b2WindowProbe.Handler as OpenHarmonyWindowHandler;
OpenHarmonyWindowHandler.MapTitle(b2WindowProbeHandler!, b2WindowProbe);
bool b2WindowTitleOk = b2WindowProbeHandler?.Title == "ohos-verify-title";
Console.WriteLine($"[verify] batch2 registration screenReader={b2ScreenReaderOk} window={b2WindowRegistered} titleMapper={b2WindowMapperKey} titleRecorded={b2WindowTitleOk} assert={b2ScreenReaderOk && b2WindowRegistered && b2WindowMapperKey && b2WindowTitleOk}");
if (!(b2ScreenReaderOk && b2WindowRegistered && b2WindowMapperKey && b2WindowTitleOk))
{
    throw new InvalidOperationException("the screen reader/window registration pins failed");
}

// D1: the screen-reader announce integration reported after the BATCH-2 pass. The managed
// screen reader now prefers the dedicated text-carrying host export
// ohos_host_accessibility_announce (EntryPoint exact, CharSet.Ansi with the same UTF-8 string
// marshalling as the node strings, int return) over the event-kind-only
// ohos_host_accessibility_send_event fallback kept for a host library that predates the export;
// the host builds an ANNOUNCE_FOR_ACCESSIBILITY event and sets the announced text on it. The
// behavioral half drives the installed default and the static call with the provider-availability
// flag restored (the flag is put back afterwards so the run is left as it was).
FieldInfo d1Availability = typeof(OpenHarmonyAccessibility).GetField("_available", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyAccessibility._available was not found; the D1 announce probe needs the provider-availability hook");
bool d1AvailabilityBefore = (bool)d1Availability.GetValue(null)!;
MethodInfo? d1AnnouncePinvoke = typeof(OpenHarmonyAccessibility).GetMethod(
    "AccessibilityAnnounce", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? d1AnnounceImport = d1AnnouncePinvoke?.GetCustomAttribute<DllImportAttribute>();
ParameterInfo[] d1AnnounceParameters = d1AnnouncePinvoke?.GetParameters() ?? Array.Empty<ParameterInfo>();
bool d1Managed = d1AnnounceImport is not null &&
    d1AnnounceImport.EntryPoint == "ohos_host_accessibility_announce" &&
    d1AnnounceImport.Value == "libopenharmonyhost.so" &&
    d1AnnounceImport.CharSet == CharSet.Ansi &&
    d1AnnouncePinvoke?.ReturnType == typeof(int) &&
    d1AnnounceParameters.Length == 1 &&
    d1AnnounceParameters[0].ParameterType == typeof(string) &&
    d1AnnounceParameters[0].GetCustomAttribute<MarshalAsAttribute>()?.Value == UnmanagedType.LPUTF8Str;
bool d1Native = hSource?.Contains("int ohos_host_accessibility_announce(const char* text);") == true &&
    s2Napi.Contains("extern \"C\" int ohos_host_accessibility_announce(const char* text)") &&
    s2Napi.Contains("OH_ArkUI_AccessibilityEventSetTextAnnouncedForAccessibility(announceEvent, text)") &&
    s2Napi.Contains("ARKUI_ACCESSIBILITY_NATIVE_EVENT_TYPE_ANNOUNCE_FOR_ACCESSIBILITY");
bool d1NoThrow = true;
bool d1Would = false;
bool d1SentOk = false;
bool d1Routed = false;
bool d1BlankOk = false;
int d1SentBefore = OpenHarmonyAccessibility.AnnouncementsSent;
try
{
    d1Availability.SetValue(null, true);
    bool d1Accepted = OpenHarmonyAccessibility.Announce("d1 direct probe");
    d1Would = OpenHarmonyAccessibility.WouldAnnounce;
    d1SentOk = OpenHarmonyAccessibility.AnnouncementsSent == d1SentBefore + (d1Accepted ? 1 : 0) &&
        OpenHarmonyAccessibility.LastAnnouncement == "d1 direct probe";
    Microsoft.Maui.Accessibility.SemanticScreenReader.Default.Announce("d1 routed probe");
    d1Routed = OpenHarmonyAccessibility.LastAnnouncement == "d1 routed probe";
    d1BlankOk = !OpenHarmonyAccessibility.Announce("   ") &&
        OpenHarmonyAccessibility.LastAnnouncement == "d1 routed probe";
}
catch (Exception ex)
{
    d1NoThrow = false;
    Console.WriteLine($"[verify] d1 announce threw {ex.GetType().Name}: {ex.Message}");
}
d1Availability.SetValue(null, d1AvailabilityBefore);
bool d1RouteOk = d1NoThrow && d1Would && d1SentOk && d1Routed && d1BlankOk;
bool d1AllOk = d1Managed && d1Native && d1RouteOk;
Console.WriteLine($"[verify] d1 announce contract managed={d1Managed} native={d1Native} route={d1RouteOk} wouldAnnounce={d1Would} sent={OpenHarmonyAccessibility.AnnouncementsSent - d1SentBefore} source='{s2NapiPath ?? "<missing>"}' assert={d1AllOk}");
if (!d1AllOk)
{
    throw new InvalidOperationException(
        $"the screen-reader announce contract drifted: managed={d1Managed} native={d1Native} route={d1RouteOk} " +
        $"wouldAnnounce={d1Would} sentOk={d1SentOk} routed={d1Routed} blank={d1BlankOk}");
}

// BATCH2i: the screenshot bridge contract (managed P/Invoke + C definition + header + NAPI sink
// + the shell's sink registration/packer call sites).
MethodInfo? b2ScreenshotPinvoke = typeof(OpenHarmonyScreenshotBridge).GetMethod(
    "ScreenshotNative", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? b2ScreenshotImport = b2ScreenshotPinvoke?.GetCustomAttribute<DllImportAttribute>();
bool b2ScreenshotManaged = b2ScreenshotImport is not null &&
    b2ScreenshotImport.EntryPoint == "ohos_host_screenshot" &&
    b2ScreenshotImport.Value == "libopenharmonyhost.so" &&
    b2ScreenshotPinvoke?.GetParameters() is { Length: 1 } b2ScreenshotParams &&
    b2ScreenshotParams[0].ParameterType == typeof(string);
bool b2ScreenshotNative = s2Napi.Contains("extern \"C\" int ohos_host_screenshot(const char* out_path)") &&
    s2Napi.Contains("HostSink screenshot{\"screenshot\", false};") &&
    hSource?.Contains("int ohos_host_screenshot(const char* out_path);") == true;
bool b2ScreenshotShell = b1Shell.Contains("this.hostCall('registerScreenshotSink', typeof host !== 'undefined' && typeof host.registerScreenshotSink === 'function'") &&
    b1Shell.Contains("host.registerScreenshotSink(async (outPath: string): Promise<void>") &&
    b1Shell.Contains("const pixelMap = await win.snapshot();") &&
    b1Shell.Contains("await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });");
bool b2ScreenshotContract = b2ScreenshotManaged && b2ScreenshotNative && b2ScreenshotShell;
Console.WriteLine($"[verify] batch2 screenshot contract managed={b2ScreenshotManaged} native={b2ScreenshotNative} shell={b2ScreenshotShell} source='{s2NapiPath ?? "<missing>"}' assert={b2ScreenshotContract}");
if (!b2ScreenshotContract)
{
    throw new InvalidOperationException(
        $"the screenshot bridge contract drifted: managed={b2ScreenshotManaged} native={b2ScreenshotNative} " +
        $"shell={b2ScreenshotShell}");
}

// BATCH2j: the geocode bridge contract (managed P/Invoke pair + C definitions + header + NAPI
// sink/answer + the shell's registerGeocodeSink/geocodeResult call sites). The managed request
// returns int (0 queued / -1 dropped) and the op map is 0 forward, 1 reverse.
MethodInfo? b2GeocodeRequest = typeof(OpenHarmonyGeocodingBridge).GetMethod(
    "GeocodeRequestNative", BindingFlags.NonPublic | BindingFlags.Static);
MethodInfo? b2GeocodeRegister = typeof(OpenHarmonyGeocodingBridge).GetMethod(
    "RegisterGeocodeResultNative", BindingFlags.NonPublic | BindingFlags.Static);
DllImportAttribute? b2GeocodeRequestImport = b2GeocodeRequest?.GetCustomAttribute<DllImportAttribute>();
DllImportAttribute? b2GeocodeRegisterImport = b2GeocodeRegister?.GetCustomAttribute<DllImportAttribute>();
bool b2GeocodeManaged = b2GeocodeRequestImport?.EntryPoint == "ohos_host_geocode_request" &&
    b2GeocodeRequestImport.Value == "libopenharmonyhost.so" &&
    b2GeocodeRequest?.ReturnType == typeof(int) &&
    b2GeocodeRequest.GetParameters() is { Length: 3 } b2GeocodeParams &&
    b2GeocodeParams[0].ParameterType == typeof(int) &&
    b2GeocodeParams[1].ParameterType == typeof(string) &&
    b2GeocodeParams[2].ParameterType == typeof(int) &&
    b2GeocodeRegisterImport?.EntryPoint == "ohos_host_register_geocode_result";
bool b2GeocodeNative = cSource?.Contains("int ohos_host_geocode_request(int op, const char* arg, int request_id)") == true &&
    cSource.Contains("static void (*g_geocode_listener)(int request_id, int op, const char* arg) = NULL;") &&
    cSource.Contains("g_app->bridge_geocode_result = (void (*)(int, int, const char*))callback;") &&
    cSource.Contains("g_app->bridge_geocode_result(request_id, rc, json != NULL ? json : \"\");") &&
    hSource?.Contains("int ohos_host_geocode_request(int op, const char* arg, int request_id);") == true &&
    hSource.Contains("void ohos_host_register_geocode_result(void* callback);") == true &&
    hSource.Contains("void ohos_host_geocode_complete(int request_id, int rc, const char* json);") == true;
bool b2GeocodeNapi = s2Napi.Contains("HostSink geocode{\"geocode\", false};") &&
    s2Napi.Contains("ohos_host_geocode_set_listener(OnGeocodeRequest);") &&
    s2Napi.Contains("ohos_host_geocode_complete(requestId, rc, json.c_str());") &&
    s2Napi.Contains("\"registerGeocodeSink\"") && s2Napi.Contains("\"geocodeResult\"");
bool b2GeocodeShell = b1Shell.Contains("this.hostCall('registerGeocodeSink', typeof host !== 'undefined' && typeof host.registerGeocodeSink === 'function'") &&
    b1Shell.Contains("host.registerGeocodeSink(async (requestId: number, op: number, arg: string): Promise<void>") &&
    b1Shell.Contains("this.hostCall('geocodeResult', typeof host !== 'undefined' && typeof host.geocodeResult === 'function'") &&
    b1Shell.Contains("host.geocodeResult(requestId, rc, json);") &&
    b1Shell.Contains("const query = JSON.parse(arg) as GeocodeAddressQuery;") &&
    b1Shell.Contains("geo.default.getAddressesFromLocationName(request)") &&
    b1Shell.Contains("geo.default.getAddressesFromLocation(request)");
bool b2GeocodeContract = b2GeocodeManaged && b2GeocodeNative && b2GeocodeNapi && b2GeocodeShell;
Console.WriteLine($"[verify] batch2 geocode contract managed={b2GeocodeManaged} native={b2GeocodeNative} napi={b2GeocodeNapi} shell={b2GeocodeShell} assert={b2GeocodeContract}");
if (!b2GeocodeContract)
{
    throw new InvalidOperationException(
        $"the geocode bridge contract drifted: managed={b2GeocodeManaged} native={b2GeocodeNative} " +
        $"napi={b2GeocodeNapi} shell={b2GeocodeShell}");
}

// BATCH2k: the optional window pin suggested with the window handler batch - the title/rect host
// exports and the shell sinks the shell-side window work registers, next to the already-checked
// managed handler/title mapper. (The managed handler still records the title; the P/Invoke that
// consumes the export is not part of this batch.)
bool b2WindowContract = hSource?.Contains("int ohos_host_set_window_title(const char* utf8);") == true &&
    hSource.Contains("int ohos_host_set_window_rect(int x, int y, int w, int h);") &&
    s2Napi.Contains("extern \"C\" int ohos_host_set_window_title(const char* utf8)") &&
    s2Napi.Contains("extern \"C\" int ohos_host_set_window_rect(int x, int y, int w, int h)") &&
    s2Napi.Contains("\"registerWindowTitleSink\"") && s2Napi.Contains("\"registerWindowRectSink\"") &&
    b1Shell.Contains("host.registerWindowTitleSink((title: string): void => {") &&
    b1Shell.Contains("host.registerWindowRectSink((x: number, y: number, w: number, h: number): void => {");
Console.WriteLine($"[verify] batch2 window contract title={hSource?.Contains("int ohos_host_set_window_title(const char* utf8);") == true} rect={hSource?.Contains("int ohos_host_set_window_rect(int x, int y, int w, int h);") == true} titleSink={s2Napi.Contains("\"registerWindowTitleSink\"")} rectSink={s2Napi.Contains("\"registerWindowRectSink\"")} shell={b1Shell.Contains("registerWindowTitleSink") && b1Shell.Contains("registerWindowRectSink")} assert={b2WindowContract}");
if (!b2WindowContract)
{
    throw new InvalidOperationException("the window title/rect host/shell contract pin failed");
}

// ---- Audit pins: previously unguarded slice features -------------------------------------------
// The follow-up audit found eight surfaces the suite exercised or referenced but never guarded
// with a source contract, so a slice refactor could silently change them between pack builds:
// the safe-area model and its app-host/page-handler usage, the FontImageSource glyph path and
// its per-source cache, the SwitchCell/EntryCell branches in the legacy ListView handler, the
// shell SearchHandler publish/listener pair, the flyout header/footer publish, the
// TabBarIsVisible/FlyoutBehavior chrome, the window title/rect publish with the host's clamp
// constants, and the shell search/flyout/window sinks in all three preview templates. Each pin
// parses the committed sources (the same style as the B3/BATCH pins above) so drift fails this
// off-device run instead of shipping a pack built from mismatched halves.

// Audit-1: safe-area model + usage. The shell's avoid area is read through
// OpenHarmonyBridge.TryGetAvoidArea, a view without an explicit configuration falls back to
// SafeAreaEdges.Container, only the overlapping part of a frame is consumed (SoftInput never
// pads the bottom), and the app host / page handler arrange through the safe-area walk; the
// host keeps the ohos_host_get_avoid_area getter the bridge wraps.
string? n1SafeAreaPath = FindHostSource("OpenHarmonySafeArea.cs");
string n1SafeArea = n1SafeAreaPath is null ? string.Empty : File.ReadAllText(n1SafeAreaPath);
string? n1SafeAreaArrangePath = FindHostSource("OpenHarmonySafeAreaArrange.cs");
string n1SafeAreaArrange = n1SafeAreaArrangePath is null ? string.Empty : File.ReadAllText(n1SafeAreaArrangePath);
string? n1AppHostPath = FindHostSource("OpenHarmonyMauiAppHost.cs");
string n1AppHost = n1AppHostPath is null ? string.Empty : File.ReadAllText(n1AppHostPath);
string? n1PageHandlerPath = FindHostSource("OpenHarmonyPageHandler.cs");
string n1PageHandler = n1PageHandlerPath is null ? string.Empty : File.ReadAllText(n1PageHandlerPath);
bool n1ModelOk = n1SafeArea.Contains("internal static class OpenHarmonySafeArea") &&
    n1SafeArea.Contains("OpenHarmonyBridge.TryGetAvoidArea(out int top, out int bottom, out int left, out int right)") &&
    n1SafeArea.Contains("return SafeAreaEdges.Container;") &&
    n1SafeArea.Contains("internal static Rect Pad(IView view, Rect frame, Rect windowBounds, Thickness insets)") &&
    n1SafeArea.Contains("isBottom && region == SafeAreaRegions.SoftInput") &&
    n1SafeArea.Contains("Math.Clamp(inset - frame.X, 0, inset)");
bool n1ArrangeOk = n1SafeAreaArrange.Contains("internal static class OpenHarmonySafeAreaArrange") &&
    n1SafeAreaArrange.Contains("private const int MaxDepth = 4;") &&
    n1SafeAreaArrange.Contains("OpenHarmonyContentArrange.Arrange(view, frame, depth);") &&
    n1SafeAreaArrange.Contains("OpenHarmonySafeArea.Pad(view, frame, windowBounds, insets)");
bool n1UsedOk = n1AppHost.Contains("Thickness insets = OpenHarmonySafeArea.GetWindowInsets();") &&
    n1AppHost.Contains("OpenHarmonySafeAreaArrange.Arrange(content, bounds, bounds, insets);") &&
    n1AppHost.Contains("OpenHarmonySafeAreaArrange.Arrange(root, bounds, bounds, insets);") &&
    n1PageHandler.Contains("OpenHarmonySafeArea.GetWindowInsets();") &&
    n1PageHandler.Contains("OpenHarmonySafeAreaArrange.Arrange(page, frame,");
bool n1HostOk = cSource?.Contains("int ohos_host_get_avoid_area(int* top, int* bottom, int* left, int* right)") == true &&
    hSource?.Contains("int ohos_host_get_avoid_area(int* top, int* bottom, int* left, int* right);") == true;
bool n1SafeAreaOk = n1ModelOk && n1ArrangeOk && n1UsedOk && n1HostOk;
Console.WriteLine($"[verify] audit safearea model={n1ModelOk} arrange={n1ArrangeOk} used={n1UsedOk} host={n1HostOk} source='{n1SafeAreaPath ?? "<missing>"}' assert={n1SafeAreaOk}");
if (!n1SafeAreaOk)
{
    throw new InvalidOperationException(
        $"the safe-area contract drifted: model={n1ModelOk} arrange={n1ArrangeOk} used={n1UsedOk} host={n1HostOk}");
}

// Audit-2: FontImageSource glyph path. The image source renderer routes a FontImageSource to
// OpenHarmonyFontImageSource (the compositor draws Text; there is no offscreen rasterizer), the
// handler's desired size asks it for the glyph metrics, and resolution is cached per unique
// glyph key (glyph/family/size/colour/scale) under a lock.
string? n2ImagePath = FindHostSource("OpenHarmonyImageHandler.cs");
string n2Image = n2ImagePath is null ? string.Empty : File.ReadAllText(n2ImagePath);
bool n2RendererOk = n2Image.Contains("else if (source is FontImageSource fontSource)") &&
    n2Image.Contains("OpenHarmonyFontImageSource.Apply(view, fontSource, context);") &&
    n2Image.Contains("internal static class OpenHarmonyFontImageSource") &&
    n2Image.Contains("public static Glyph Resolve(FontImageSource source)") &&
    n2Image.Contains("Size glyph = OpenHarmonyFontImageSource.Measure(fontSource);");
bool n2CacheOk = n2Image.Contains("private static readonly Dictionary<GlyphKey, Glyph> s_cache = new();") &&
    n2Image.Contains("if (!s_cache.TryGetValue(key, out Glyph? glyph))") &&
    n2Image.Contains("s_cache[key] = glyph;") &&
    n2Image.Contains("(float width, float height) = OpenHarmonyLabelHandler.MeasureText(text, fontSize);");
bool n2FontOk = n2RendererOk && n2CacheOk;
Console.WriteLine($"[verify] audit fontimage renderer={n2RendererOk} cache={n2CacheOk} source='{n2ImagePath ?? "<missing>"}' assert={n2FontOk}");
if (!n2FontOk)
{
    throw new InvalidOperationException($"the FontImageSource contract drifted: renderer={n2RendererOk} cache={n2CacheOk}");
}

// Audit-3: SwitchCell/EntryCell materialisation in the legacy ListView handler. Both branches
// build a label + interactive control row: the switch writes taps back to On, and the entry
// keeps the standard Entry keyboard/text path and raises SendCompleted.
string? n3ListPath = FindHostSource("OpenHarmonyListViewHandler.cs");
string n3List = n3ListPath is null ? string.Empty : File.ReadAllText(n3ListPath);
bool n3SwitchOk = n3List.Contains("SwitchCell switchCell => CreateSwitchCell(switchCell),") &&
    n3List.Contains("private static View CreateSwitchCell(SwitchCell cell)") &&
    n3List.Contains("toggle.Toggled += (_, e) => cell.On = e.Value;");
bool n3EntryOk = n3List.Contains("EntryCell entryCell => CreateEntryCell(entryCell),") &&
    n3List.Contains("private static View CreateEntryCell(EntryCell cell)") &&
    n3List.Contains("entry.TextChanged += (_, e) => cell.Text = e.NewTextValue;") &&
    n3List.Contains("entry.Completed += (_, _) => cell.SendCompleted();");
bool n3CellsOk = n3SwitchOk && n3EntryOk && n3List.Contains("private static View CreateCellRow(View content, View trailing)");
Console.WriteLine($"[verify] audit listcells switch={n3SwitchOk} entry={n3EntryOk} row={n3List.Contains("CreateCellRow")} source='{n3ListPath ?? "<missing>"}' assert={n3CellsOk}");
if (!n3CellsOk)
{
    throw new InvalidOperationException($"the SwitchCell/EntryCell contract drifted: switch={n3SwitchOk} entry={n3EntryOk}");
}

// Audit-4: the shell SearchHandler bridge. The managed half declares
// ohos_host_shell_search_set / ohos_host_shell_search_set_listener (the same probe pattern),
// publishes a changed query/placeholder/visible/enabled payload (clearing the field on detach)
// and routes the host's op 0/1/2 back to Query / QueryConfirmed; the handler attaches the
// current page's search handler (shell fallback) through OpenHarmonyShellExtras.UpdateSearch.
string? n4ExtrasPath = FindHostSource("OpenHarmonyShellExtras.cs");
string n4Extras = n4ExtrasPath is null ? string.Empty : File.ReadAllText(n4ExtrasPath);
string? n4ShellHandlerPath = FindHostSource("OpenHarmonyShellHandler.cs");
string n4ShellHandler = n4ShellHandlerPath is null ? string.Empty : File.ReadAllText(n4ShellHandlerPath);
bool n4ManagedOk = n4Extras.Contains("private const string SearchSetEntryPoint = \"ohos_host_shell_search_set\";") &&
    n4Extras.Contains("private const string SearchListenerEntryPoint = \"ohos_host_shell_search_set_listener\";") &&
    n4Extras.Contains("[DllImport(HostLibrary, EntryPoint = SearchSetEntryPoint, CharSet = CharSet.Ansi)]") &&
    n4Extras.Contains("[DllImport(HostLibrary, EntryPoint = SearchListenerEntryPoint)]") &&
    n4Extras.Contains("private delegate void SearchInteractionCallback(int op, IntPtr text);") &&
    n4Extras.Contains("private static extern int ShellSearchSetNative(");
bool n4PublishOk = n4Extras.Contains("private static void PublishSearch(OpenHarmonyShellSearchState state)") &&
    n4Extras.Contains("ShellSearchSetNative(") &&
    n4Extras.Contains("state.IsVisible ? state.Query : null,") &&
    n4Extras.Contains("state.IsVisible ? 1 : 0,") &&
    n4Extras.Contains("state.IsEnabled ? 1 : 0);") &&
    n4Extras.Contains("EnsureSearchListener();") &&
    n4Extras.Contains("ShellSearchSetListenerNative(Marshal.GetFunctionPointerForDelegate(s_searchInteractionThunk));") &&
    n4Extras.Contains("handler.Query = text;") &&
    n4Extras.Contains("controller.QueryConfirmed();") &&
    n4Extras.Contains("handler.Query = string.Empty;");
bool n4AttachOk = n4Extras.Contains("internal static void UpdateSearch(Microsoft.Maui.Controls.SearchHandler? handler, string? pageTitle)") &&
    n4ShellHandler.Contains("private void AttachSearchHandler(SearchHandler? handler, Microsoft.Maui.Controls.Page? page)") &&
    n4ShellHandler.Contains("OpenHarmonyShellExtras.UpdateSearch(handler, page?.Title);") &&
    n4ShellHandler.Contains("SearchHandler? handler = page is not null ? Shell.GetSearchHandler(page) : null;") &&
    n4ShellHandler.Contains("handler ??= Shell.GetSearchHandler(shell);") &&
    n4ShellHandler.Contains("OpenHarmonyShellExtras.UpdateSearch(null, null);");
bool n4SearchOk = n4ManagedOk && n4PublishOk && n4AttachOk;
Console.WriteLine($"[verify] audit search managed={n4ManagedOk} publish={n4PublishOk} attach={n4AttachOk} source='{n4ExtrasPath ?? "<missing>"}' assert={n4SearchOk}");
if (!n4SearchOk)
{
    throw new InvalidOperationException(
        $"the shell search bridge contract drifted: managed={n4ManagedOk} publish={n4PublishOk} attach={n4AttachOk}");
}

// Audit-5: flyout header/footer publish. A string or Label section crosses
// ohos_host_shell_flyout_header/footer (NULL/empty clears the shell label), the same text stays
// the first/last compositor flyout row (selection offset by the leading header row), and a rich
// View/DataTemplate still has no representation (SectionText returns null).
string? n5FlyoutPath = n4ExtrasPath;
string n5Flyout = n4Extras;
bool n5PublishOk = n5Flyout.Contains("private const string FlyoutHeaderEntryPoint = \"ohos_host_shell_flyout_header\";") &&
    n5Flyout.Contains("private const string FlyoutFooterEntryPoint = \"ohos_host_shell_flyout_footer\";") &&
    n5Flyout.Contains("private static extern int ShellFlyoutHeaderNative(") &&
    n5Flyout.Contains("private static extern int ShellFlyoutFooterNative(") &&
    n5Flyout.Contains("internal static void SetFlyoutSections(string? header, string? footer)") &&
    n5Flyout.Contains("PublishFlyoutSection(0, header);") &&
    n5Flyout.Contains("PublishFlyoutSection(1, footer);") &&
    n5Flyout.Contains("private static void PublishFlyoutSection(int op, string? text)") &&
    n5Flyout.Contains("header ? ShellFlyoutHeaderNative(text) : ShellFlyoutFooterNative(text);") &&
    n5Flyout.Contains("public static string? SectionText(object? section) => section switch");
bool n5RowsOk = n4ShellHandler.Contains("OpenHarmonyShellExtras.SetFlyoutSections(header, footer);") &&
    n4ShellHandler.Contains("public static void MapFlyoutSections(OpenHarmonyShellHandler handler, Shell shell)") &&
    n4ShellHandler.Contains("view.FlyoutItems.Add(header);") &&
    n4ShellHandler.Contains("handler._flyoutLeadingRows = 1;");
bool n5FlyoutOk = n5PublishOk && n5RowsOk;
Console.WriteLine($"[verify] audit flyout publish={n5PublishOk} rows={n5RowsOk} source='{n5FlyoutPath ?? "<missing>"}' assert={n5FlyoutOk}");
if (!n5FlyoutOk)
{
    throw new InvalidOperationException($"the flyout header/footer contract drifted: publish={n5PublishOk} rows={n5RowsOk}");
}

// Audit-6: Shell.TabBarIsVisible / Shell.FlyoutBehavior. The tab-bar flag resolves the nearest
// explicit attached property on the current page or an ancestor, then the shell (visible when
// unset), and re-arranges the content; the flyout behavior hides+closes for Disabled and pins
// the drawer open for Locked without forcing a full chrome sync on navigation.
bool n6TabBarOk = n4ShellHandler.Contains("[\"TabBarIsVisible\"] = MapTabBar,") &&
    n4ShellHandler.Contains("private static bool ResolveTabBarVisible(Shell shell)") &&
    n4ShellHandler.Contains("element.IsSet(Shell.TabBarIsVisibleProperty)") &&
    n4ShellHandler.Contains("handler.PlatformView.TabTitlesVisible = ResolveTabBarVisible(shell);") &&
    n4ShellHandler.Contains("case \"TabBarIsVisible\":");
bool n6FlyoutOk = n4ShellHandler.Contains("[nameof(Shell.FlyoutBehavior)] = MapFlyoutBehavior,") &&
    n4ShellHandler.Contains("view.ShowsHamburger = shell.FlyoutBehavior != FlyoutBehavior.Disabled;") &&
    n4ShellHandler.Contains("if (shell.FlyoutBehavior == FlyoutBehavior.Disabled)") &&
    n4ShellHandler.Contains("view.FlyoutOpen = false;") &&
    n4ShellHandler.Contains("else if (shell.FlyoutBehavior == FlyoutBehavior.Locked)") &&
    n4ShellHandler.Contains("view.FlyoutOpen = true;");
bool n6ChromeOk = n6TabBarOk && n6FlyoutOk;
Console.WriteLine($"[verify] audit shellchrome tabbar={n6TabBarOk} flyout={n6FlyoutOk} source='{n4ShellHandlerPath ?? "<missing>"}' assert={n6ChromeOk}");
if (!n6ChromeOk)
{
    throw new InvalidOperationException($"the TabBarIsVisible/FlyoutBehavior contract drifted: tabbar={n6TabBarOk} flyout={n6FlyoutOk}");
}

// Audit-7: the window chrome publish (NB1). Title and X/Y/Width/Height are forwarded to
// ohos_host_set_window_title / ohos_host_set_window_rect through the cached export probes, the
// X/Y/Width/Height mappers keep recording the values, and a rectangle is only published once a
// usable width/height is known (a non-positive size is rejected by the host).
string? n7WindowPath = FindHostSource("OpenHarmonyWindowHandler.cs");
string n7Window = n7WindowPath is null ? string.Empty : File.ReadAllText(n7WindowPath);
bool n7ImportsOk = n7Window.Contains("private const string TitleEntryPoint = \"ohos_host_set_window_title\";") &&
    n7Window.Contains("private const string RectEntryPoint = \"ohos_host_set_window_rect\";") &&
    n7Window.Contains("[DllImport(HostLibrary, EntryPoint = TitleEntryPoint, CharSet = CharSet.Ansi)]") &&
    n7Window.Contains("[DllImport(HostLibrary, EntryPoint = RectEntryPoint)]") &&
    n7Window.Contains("private static extern int SetWindowTitleNative(") &&
    n7Window.Contains("private static extern int SetWindowRectNative(int x, int y, int w, int h);");
bool n7MappersOk = n7Window.Contains("[nameof(IWindow.X)] = MapX,") &&
    n7Window.Contains("[nameof(IWindow.Y)] = MapY,") &&
    n7Window.Contains("[nameof(IWindow.Width)] = MapWidth,") &&
    n7Window.Contains("[nameof(IWindow.Height)] = MapHeight,") &&
    n7Window.Contains("PublishTitle(window.Title);");
bool n7PublishOk = n7Window.Contains("private static void PublishRect(OpenHarmonyWindowHandler handler)") &&
    n7Window.Contains("if (!(handler.Width > 0) || !(handler.Height > 0))") &&
    n7Window.Contains("int rc = SetWindowRectNative(x, y, w, h);") &&
    n7Window.Contains("int rc = SetWindowTitleNative(title);") &&
    n7Window.Contains("private static bool TryToDevice(double value, out int result)") &&
    n7Window.Contains("result = (int)Math.Round(value, MidpointRounding.AwayFromZero);");
bool n7WindowOk = n7ImportsOk && n7MappersOk && n7PublishOk;
Console.WriteLine($"[verify] audit windowrect imports={n7ImportsOk} mappers={n7MappersOk} publish={n7PublishOk} source='{n7WindowPath ?? "<missing>"}' assert={n7WindowOk}");
if (!n7WindowOk)
{
    throw new InvalidOperationException(
        $"the window chrome contract drifted: imports={n7ImportsOk} mappers={n7MappersOk} publish={n7PublishOk}");
}

// Audit-8: the host's window-rect clamps. The shell applies the queued rectangle with
// moveWindowTo + resize, so the host rejects a non-positive size and clamps width/height into
// (0, 16384] and x/y into [-32768, 32768] on both bounds before queueing the sink call.
bool n8ClampOk = s2Napi.Contains("constexpr int kMaxWindowDimension = 16384;") &&
    s2Napi.Contains("constexpr int kMaxWindowOffset = 32768;") &&
    s2Napi.Contains("int ohos_host_set_window_rect(int x, int y, int w, int h) {") &&
    s2Napi.Contains("if (w <= 0 || h <= 0) {") &&
    s2Napi.Contains("if (w > kMaxWindowDimension) {") && s2Napi.Contains("w = kMaxWindowDimension;") &&
    s2Napi.Contains("if (h > kMaxWindowDimension) {") && s2Napi.Contains("h = kMaxWindowDimension;") &&
    s2Napi.Contains("if (x > kMaxWindowOffset) {") && s2Napi.Contains("x = kMaxWindowOffset;") &&
    s2Napi.Contains("} else if (x < -kMaxWindowOffset) {") && s2Napi.Contains("x = -kMaxWindowOffset;") &&
    s2Napi.Contains("if (y > kMaxWindowOffset) {") && s2Napi.Contains("y = kMaxWindowOffset;") &&
    s2Napi.Contains("} else if (y < -kMaxWindowOffset) {") && s2Napi.Contains("y = -kMaxWindowOffset;") &&
    s2Napi.Contains("HostSinkPost(g_window_rect_sink, call)");
bool n8HeaderOk = hSource?.Contains("int ohos_host_set_window_rect(int x, int y, int w, int h);") == true;
bool n8HostOk = n8ClampOk && n8HeaderOk;
Console.WriteLine($"[verify] audit windowhost clamps={n8ClampOk} header={n8HeaderOk} source='{s2NapiPath ?? "<missing>"}' assert={n8HostOk}");
if (!n8HostOk)
{
    throw new InvalidOperationException($"the host window-rect clamp contract drifted: clamps={n8ClampOk} header={n8HeaderOk}");
}

// Audit-9: the shell search/flyout/window sinks in all three preview templates. Every template
// registers the same callbacks (search state assignment, flyout op 0/1, window title/rect
// apply), reports search edits/submits/cancels back through host.notifyShellSearch and applies
// the window chrome with setWindowTitle / moveWindowTo+resize; the three files stay identical.
bool n9SearchSink = true;
bool n9FlyoutSink = true;
bool n9WindowSink = true;
bool n9SearchNotify = true;
bool n9WindowApply = true;
foreach (string n9Version in b3ShellVersions)
{
    string? n9Path = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{n9Version}/templates/ets/pages/Index.ets");
    string n9Shell = n9Path is null ? string.Empty : File.ReadAllText(n9Path);
    n9SearchSink &= n9Shell.Contains("host.registerShellSearchChangedSink((query: string, placeholder: string, visible: number, enabled: number): void => {") &&
        n9Shell.Contains("this.shellSearchQuery = query;") &&
        n9Shell.Contains("this.shellSearchPlaceholder = placeholder;") &&
        n9Shell.Contains("this.shellSearchVisible = visible !== 0;") &&
        n9Shell.Contains("this.shellSearchEnabled = enabled !== 0;");
    n9FlyoutSink &= n9Shell.Contains("host.registerShellFlyoutChangedSink((op: number, text: string): void => {") &&
        n9Shell.Contains("if (op === 0) {") &&
        n9Shell.Contains("} else if (op === 1) {");
    n9WindowSink &= n9Shell.Contains("host.registerWindowTitleSink((title: string): void => {") &&
        n9Shell.Contains("this.applyWindowTitle(title);") &&
        n9Shell.Contains("host.registerWindowRectSink((x: number, y: number, w: number, h: number): void => {") &&
        n9Shell.Contains("this.applyWindowRect(x, y, w, h);");
    n9SearchNotify &= n9Shell.Contains("host.notifyShellSearch(0, value);") &&
        n9Shell.Contains("host.notifyShellSearch(1, this.shellSearchQuery);") &&
        n9Shell.Contains("host.notifyShellSearch(2, '');");
    n9WindowApply &= n9Shell.Contains("return win.setWindowTitle(title);") &&
        n9Shell.Contains("return win.moveWindowTo(x, y).then(() => {") &&
        n9Shell.Contains("return win.resize(w, h);");
}
bool n9SinksOk = n9SearchSink && n9FlyoutSink && n9WindowSink && n9SearchNotify && n9WindowApply && b1ShellIdentical;
Console.WriteLine($"[verify] audit shell sinks packs=22,23,24 search={n9SearchSink} flyout={n9FlyoutSink} window={n9WindowSink} notify={n9SearchNotify} apply={n9WindowApply} identical={b1ShellIdentical} assert={n9SinksOk}");
if (!n9SinksOk)
{
    throw new InvalidOperationException(
        $"the shell sink contract drifted: search={n9SearchSink} flyout={n9FlyoutSink} window={n9WindowSink} " +
        $"notify={n9SearchNotify} apply={n9WindowApply} identical={b1ShellIdentical}");
}

// ---- Audit batch 2 pins: BLE/lifecycle/list extras/settings/webauth/soft-input/PE2/PJ ----------
// The post-PG2 audit found nine shipped surfaces with zero source-contract coverage, so a slice
// refactor could change them between pack builds without failing this run. Each pin below parses
// the committed sources (the same style as the audit pins above): the BLE GATT bridge, the
// IApplication handler and the Created/Activated ordering, the CollectionView extras and the
// shared materializer, the settings/bundle/PostNotifications bridges, the WebAuthenticator
// degrade, the soft-input inset + ConnectionProfiles push, the PE2 focus/key files, the Shell
// TitleView/toolbar chrome, and the PJ1/PJ2 frame-loop managers (animation loop, scroll physics,
// scrollbars, focus ring, tooltip and keyboard-accelerator managers).

string ShellSource(string version) =>
    FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{version}/templates/ets/pages/Index.ets") is { } shellPath
        ? File.ReadAllText(shellPath)
        : string.Empty;

// Audit2-1: BLE GATT (platform extra). The managed side declares the request/result/event
// P/Invokes plus the two callback delegates (ACCESS_BLUETOOTH probe), the shared header declares
// and the NAPI layer implements the five exports (sink post, result/event dispatch, module-table
// names), and all three shell templates register the sink (requesting ACCESS_BLUETOOTH with the
// on-demand Connectivity Kit import) and answer through notifyBluetoothGattResult/Event.
string? n10GattPath = FindHostSource("OpenHarmonyBluetoothGatt.cs");
string n10Gatt = n10GattPath is null ? string.Empty : File.ReadAllText(n10GattPath);
bool n10ManagedOk = n10Gatt.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_bluetooth_gatt_request\", CharSet = CharSet.Ansi)]") &&
    n10Gatt.Contains("private static extern int BluetoothGattRequest(int requestId, int op, string payload);") &&
    n10Gatt.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_bluetooth_gatt_register_result\")]") &&
    n10Gatt.Contains("private static extern void BluetoothGattRegisterResult(IntPtr callback);") &&
    n10Gatt.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_bluetooth_gatt_register_event\")]") &&
    n10Gatt.Contains("private static extern void BluetoothGattRegisterEvent(IntPtr callback);") &&
    n10Gatt.Contains("private delegate void GattResultCallback(int requestId, int code, IntPtr payloadUtf8);") &&
    n10Gatt.Contains("private delegate void GattEventCallback(IntPtr payloadUtf8);") &&
    n10Gatt.Contains("OpenHarmonyBridge.CheckSelfPermission(\"ohos.permission.ACCESS_BLUETOOTH\")");
bool n10HeaderOk = hSource?.Contains("int ohos_host_bluetooth_gatt_request(int request_id, int op, const char* payload);") == true &&
    hSource.Contains("void ohos_host_bluetooth_gatt_register_result(void* callback);") &&
    hSource.Contains("void ohos_host_bluetooth_gatt_result(int request_id, int code, const char* payload);") &&
    hSource.Contains("void ohos_host_bluetooth_gatt_register_event(void* callback);") &&
    hSource.Contains("void ohos_host_bluetooth_gatt_event(const char* payload);");
bool n10HostOk = s2Napi.Contains("extern \"C\" int ohos_host_bluetooth_gatt_request(int request_id, int op, const char* payload) {") &&
    s2Napi.Contains("if (!HostSinkPost(g_bluetooth_gatt_sink, call)) {") &&
    s2Napi.Contains("extern \"C\" void ohos_host_bluetooth_gatt_result(int request_id, int code, const char* payload) {") &&
    s2Napi.Contains("extern \"C\" void ohos_host_bluetooth_gatt_event(const char* payload) {") &&
    s2Napi.Contains("\"registerBluetoothGattSink\"") &&
    s2Napi.Contains("\"notifyBluetoothGattResult\"") &&
    s2Napi.Contains("\"notifyBluetoothGattEvent\"");
bool n10ShellOk = true;
foreach (string n10Version in b3ShellVersions)
{
    string n10Shell = ShellSource(n10Version);
    n10ShellOk &= n10Shell.Contains("this.hostCall('registerBluetoothGattSink', typeof host !== 'undefined' && typeof host.registerBluetoothGattSink === 'function', (): void => {") &&
        n10Shell.Contains("host.registerBluetoothGattSink(async (requestId: number, op: number, payload: string): Promise<void> => {") &&
        n10Shell.Contains("const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];") &&
        n10Shell.Contains("host.notifyBluetoothGattResult(requestId, code, payload);") &&
        n10Shell.Contains("host.notifyBluetoothGattEvent(`mtu\\t${this.escapeRecordField(address)}\\t${mtu}`);");
}
bool n10GattOk = n10ManagedOk && n10HeaderOk && n10HostOk && n10ShellOk;
Console.WriteLine($"[verify] audit2 ble gatt managed={n10ManagedOk} header={n10HeaderOk} host={n10HostOk} shell={n10ShellOk} source='{n10GattPath ?? "<missing>"}' assert={n10GattOk}");
if (!n10GattOk)
{
    throw new InvalidOperationException(
        $"the BLE GATT contract drifted: managed={n10ManagedOk} header={n10HeaderOk} host={n10HostOk} shell={n10ShellOk}");
}

// Audit2-2: IApplication/lifecycle. The slice handler is the IApplication ElementHandler with
// the four command-mapper entries and the single-surface window semantics; the app host raises
// IWindow.Created before IWindow.Activated for the platform Create event (and Created from Run
// when the event arrived first) with the once-guards; the hosting enum numbers the platform
// events (Create=0, Destroy=1, Foreground=2, Background=3); and the shell templates send the
// Foreground lifecycle (2) from aboutToAppear. NOTE: the Create=0 send is the PI1 follow-up and
// is reported (createSend) but not required yet - pin what exists.
string? n11HandlerPath = FindHostSource("OpenHarmonyApplicationHandler.cs");
string n11Handler = n11HandlerPath is null ? string.Empty : File.ReadAllText(n11HandlerPath);
string? n11AppHostPath = FindHostSource("OpenHarmonyMauiAppHost.cs");
string n11AppHost = n11AppHostPath is null ? string.Empty : File.ReadAllText(n11AppHostPath);
string? n11HostingPath = FindHostSource("src/Microsoft.OpenHarmony.Hosting/OpenHarmonyApp.cs");
string n11Hosting = n11HostingPath is null ? string.Empty : File.ReadAllText(n11HostingPath);
bool n11HandlerOk = n11Handler.Contains("public sealed class OpenHarmonyApplicationHandler : ElementHandler<IApplication, OpenHarmonyPlatformApplication>") &&
    n11Handler.Contains("[TerminateCommandKey] = MapTerminate,") &&
    n11Handler.Contains("[nameof(IApplication.OpenWindow)] = MapOpenWindow,") &&
    n11Handler.Contains("[nameof(IApplication.CloseWindow)] = MapCloseWindow,") &&
    n11Handler.Contains("[nameof(IApplication.ActivateWindow)] = MapActivateWindow,") &&
    n11Handler.Contains("window.Activated();");
int n11CreateAt = n11AppHost.IndexOf("case OpenHarmonyLifecycleEvent.Create:", StringComparison.Ordinal);
int n11CreatedAt = n11CreateAt < 0 ? -1 : n11AppHost.IndexOf("EnsureWindowCreated();", n11CreateAt, StringComparison.Ordinal);
int n11ActivatedAt = n11CreatedAt < 0 ? -1 : n11AppHost.IndexOf("EnsureWindowActivated();", n11CreatedAt, StringComparison.Ordinal);
bool n11OrderOk = n11CreateAt >= 0 && n11CreatedAt > n11CreateAt && n11ActivatedAt > n11CreatedAt &&
    n11AppHost.Contains("EnsureWindowCreated();\n        _dirty = true;") &&
    n11AppHost.Contains("private void EnsureWindowCreated()") &&
    n11AppHost.Contains("_created = true;\n        _window.Created();") &&
    n11AppHost.Contains("private void EnsureWindowActivated()") &&
    n11AppHost.Contains("_activated = true;\n        _window.Activated();") &&
    n11AppHost.Contains("_window?.Resumed();") &&
    n11AppHost.Contains("_window?.Stopped();") &&
    n11AppHost.Contains("_window?.Destroying();");
bool n11HostingOk = n11Hosting.Contains("Create = 0,") &&
    n11Hosting.Contains("Destroy = 1,") &&
    n11Hosting.Contains("Foreground = 2,") &&
    n11Hosting.Contains("Background = 3,");
bool n11ShellOk = true;
bool n11CreateSend = false;
foreach (string n11Version in b3ShellVersions)
{
    string n11Shell = ShellSource(n11Version);
    n11ShellOk &= n11Shell.Contains("this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {") &&
        n11Shell.Contains("host.notifyLifecycle(2);");
    n11CreateSend |= n11Shell.Contains("host.notifyLifecycle(0);");
}
bool n11LifecycleOk = n11HandlerOk && n11OrderOk && n11HostingOk && n11ShellOk;
Console.WriteLine($"[verify] audit2 lifecycle handler={n11HandlerOk} createdBeforeActivated={n11OrderOk} enum={n11HostingOk} shellForeground={n11ShellOk} createSend={n11CreateSend} source='{n11AppHostPath ?? "<missing>"}' assert={n11LifecycleOk}");
if (!n11LifecycleOk)
{
    throw new InvalidOperationException(
        $"the IApplication/lifecycle contract drifted: handler={n11HandlerOk} order={n11OrderOk} enum={n11HostingOk} shell={n11ShellOk}");
}

// Audit2-3: CollectionView extras. The handler maps EmptyView/EmptyViewTemplate, Header/Footer,
// SelectedItems/SelectionMode and RemainingItemsThreshold, subscribes ScrollToRequested, and the
// shared materializer builds header/footer/EmptyView rows, tracks groups for ScrollTo and reports
// the last visible item for the threshold; multiple selection reads SelectedItems.
string? n12ListPath = FindHostSource("OpenHarmonyCollectionViewHandler.cs");
string n12List = n12ListPath is null ? string.Empty : File.ReadAllText(n12ListPath);
string? n12MatPath = FindHostSource("OpenHarmonyItemListMaterializer.cs");
string n12Mat = n12MatPath is null ? string.Empty : File.ReadAllText(n12MatPath);
bool n12MapsOk = n12List.Contains("[nameof(ItemsView.EmptyView)] = MapEmptyView,") &&
    n12List.Contains("[nameof(ItemsView.EmptyViewTemplate)] = MapEmptyView,") &&
    n12List.Contains("[nameof(StructuredItemsView.Header)] = MapHeaderFooter,") &&
    n12List.Contains("[nameof(StructuredItemsView.Footer)] = MapHeaderFooter,") &&
    n12List.Contains("[nameof(SelectableItemsView.SelectedItems)] = MapSelectedItems,") &&
    n12List.Contains("[nameof(SelectableItemsView.SelectionMode)] = MapSelectionMode,") &&
    n12List.Contains("[nameof(ItemsView.RemainingItemsThreshold)] = MapRemainingItemsThreshold,") &&
    n12List.Contains("collection.ScrollToRequested += OnScrollToRequested;");
bool n12ExtrasOk = n12List.Contains("emptyViewFactory = CreateEmptyView,") &&
    n12List.Contains("private View? CreateListHeader()") &&
    n12List.Contains("private View? CreateListFooter()") &&
    n12List.Contains("case SelectionMode.Multiple:") &&
    n12List.Contains("collectionView.SelectedItems?.Contains(context) == true") &&
    n12List.Contains("collection.SendRemainingItemsThresholdReached();");
bool n12ScrollOk = n12List.Contains("private void OnScrollToRequested(object? sender, ScrollToRequestEventArgs args)") &&
    n12List.Contains("materializer.RowForGroupItemIndex(args.GroupIndex, args.Index)") &&
    n12List.Contains("materializer.ScrollTo(row, args.ScrollToPosition);") &&
    n12Mat.Contains("internal sealed class OpenHarmonyItemListMaterializer") &&
    n12Mat.Contains("public Func<View?>? listHeaderFactory;") &&
    n12Mat.Contains("public Func<View?>? listFooterFactory;") &&
    n12Mat.Contains("public Func<View?>? emptyViewFactory;") &&
    n12Mat.Contains("public void ScrollTo(int row, ScrollToPosition position)") &&
    n12Mat.Contains("public int RowForGroupItemIndex(int groupIndex, int itemIndex)");
bool n12WindowOk = n12Mat.Contains("public double TotalHeight => _headerHeight + RowCount * SlotHeight + _footerHeight;") &&
    n12Mat.Contains("public bool HasGroups => _groups.Count > 0;") &&
    n12Mat.Contains("public double EmptyHeight => _emptyHeight;") &&
    n12Mat.Contains("public int LastVisibleItemIndex");
bool n12ListExtrasOk = n12MapsOk && n12ExtrasOk && n12ScrollOk && n12WindowOk;
Console.WriteLine($"[verify] audit2 listextras maps={n12MapsOk} extras={n12ExtrasOk} scrollto={n12ScrollOk} window={n12WindowOk} source='{n12MatPath ?? "<missing>"}' assert={n12ListExtrasOk}");
if (!n12ListExtrasOk)
{
    throw new InvalidOperationException(
        $"the CollectionView extras contract drifted: maps={n12MapsOk} extras={n12ExtrasOk} scrollto={n12ScrollOk} window={n12WindowOk}");
}

// Audit2-4: settings/bundle/PostNotifications. AppInfo opens the settings app through the shared
// ability-start kind 4 (uri = bundle name, text = ability name) and reads the HAP's bundle
// metadata from the host's ohos_host_get_bundle_* getters (the shell publishes it once through
// host.setBundleInfo); Permissions.PostNotifications rides its own enablement bridge
// (notification_permission_request/register_result, shell isNotificationEnabledSync /
// requestEnableNotification answe back through host.notificationPermissionResult) because
// abilityAccessCtrl has no such permission.
string? n13AppInfoPath = FindHostSource("OpenHarmonyAppInfo.cs");
string n13AppInfo = n13AppInfoPath is null ? string.Empty : File.ReadAllText(n13AppInfoPath);
string? n13EssentialsPath = FindHostSource("OpenHarmonyEssentialsUnsupported.cs");
string n13Essentials = n13EssentialsPath is null ? string.Empty : File.ReadAllText(n13EssentialsPath);
bool n13SettingsOk = n13AppInfo.Contains("private const int KindSettings = 4;") &&
    n13AppInfo.Contains("private const string SettingsBundle = \"com.ohos.settings\";") &&
    n13AppInfo.Contains("private const string SettingsAbility = \"com.ohos.settings.MainAbility\";") &&
    n13AppInfo.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_ability_start\", CharSet = CharSet.Ansi)]") &&
    n13AppInfo.Contains("return AbilityStart(KindSettings, SettingsBundle, SettingsAbility) == 0;");
bool n13BundleOk = n13AppInfo.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_get_bundle_version\")]") &&
    n13AppInfo.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_get_bundle_build\")]") &&
    n13AppInfo.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_get_bundle_name\")]") &&
    n13AppInfo.Contains("public string VersionString => OpenHarmonyBundleInfoBridge.Version ?? FallbackVersion;") &&
    hSource?.Contains("int ohos_host_set_bundle_info(const char* version, const char* build, const char* name);") == true &&
    hSource.Contains("const char* ohos_host_get_bundle_version(void);") &&
    hSource.Contains("const char* ohos_host_get_bundle_build(void);") &&
    hSource.Contains("const char* ohos_host_get_bundle_name(void);") &&
    cSource?.Contains("int ohos_host_set_bundle_info(const char* version, const char* build, const char* name) {") == true &&
    cSource.Contains("static pthread_mutex_t g_bundle_info_mutex = PTHREAD_MUTEX_INITIALIZER;") &&
    cSource.Contains("const char* ohos_host_get_bundle_name(void) {") &&
    s2Napi.Contains("napi_value SetBundleInfo(napi_env env, napi_callback_info info) {") &&
    s2Napi.Contains("\"setBundleInfo\"");
bool n13NotificationsOk = n13Essentials.Contains("internal static class OpenHarmonyNotificationPermissionBridge") &&
    n13Essentials.Contains("internal const int QueryOp = 0;") &&
    n13Essentials.Contains("internal const int RequestOp = 1;") &&
    n13Essentials.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_notification_permission_request\")]") &&
    n13Essentials.Contains("private static extern void RequestNative(int op, int requestId);") &&
    n13Essentials.Contains("typeof(TPermission) == typeof(Permissions.PostNotifications)") &&
    hSource?.Contains("void ohos_host_notification_permission_set_listener(void (*listener)(int op, int request_id));") == true &&
    hSource.Contains("void ohos_host_notification_permission_request(int op, int request_id);") &&
    hSource.Contains("void ohos_host_notification_permission_register_result(void* callback);") &&
    hSource.Contains("void ohos_host_notification_permission_complete(int request_id, int granted);") &&
    cSource?.Contains("static void (*g_notification_permission_listener)(int op, int request_id) = NULL;") == true &&
    cSource.Contains("void ohos_host_notification_permission_complete(int request_id, int granted) {") &&
    s2Napi.Contains("napi_value RegisterNotificationPermissionSink(napi_env env, napi_callback_info info) {") &&
    s2Napi.Contains("\"registerNotificationPermissionSink\"") &&
    s2Napi.Contains("\"notificationPermissionResult\"");
bool n13ShellOk = true;
foreach (string n13Version in b3ShellVersions)
{
    string n13Shell = ShellSource(n13Version);
    n13ShellOk &= n13Shell.Contains("getBundleInfoForSelfSync(") &&
        n13Shell.Contains("host.setBundleInfo(info.versionName, `${info.versionCode}`, info.name);") &&
        n13Shell.Contains("this.hostCall('registerNotificationPermissionSink', typeof host !== 'undefined' && typeof host.registerNotificationPermissionSink === 'function', (): void => {") &&
        n13Shell.Contains("host.registerNotificationPermissionSink(async (op: number, requestId: number): Promise<void> => {") &&
        n13Shell.Contains("await nm.default.requestEnableNotification(context);") &&
        n13Shell.Contains("granted = nm.default.isNotificationEnabledSync();") &&
        n13Shell.Contains("host.notificationPermissionResult(requestId, granted ? 1 : 0);");
}
bool n13SettingsBundleOk = n13SettingsOk && n13BundleOk && n13NotificationsOk && n13ShellOk;
Console.WriteLine($"[verify] audit2 settings kind4={n13SettingsOk} bundle={n13BundleOk} notifications={n13NotificationsOk} shell={n13ShellOk} source='{n13AppInfoPath ?? "<missing>"}' assert={n13SettingsBundleOk}");
if (!n13SettingsBundleOk)
{
    throw new InvalidOperationException(
        $"the settings/bundle/PostNotifications contract drifted: settings={n13SettingsOk} bundle={n13BundleOk} notifications={n13NotificationsOk} shell={n13ShellOk}");
}

// Audit2-5: WebAuthenticator degrade. The slice implementation is installed both as
// WebAuthenticator.Default (ModuleInitializer + reflection on the internal defaultImplementation
// field) and in DI, and AuthenticateAsync fails fast with FeatureNotSupportedException (the
// documented missing callback-skill/want-forward diagnosis), never the reference-assembly
// exception.
string? n14WebAuthPath = FindHostSource("OpenHarmonyWebAuthenticator.cs");
string n14WebAuth = n14WebAuthPath is null ? string.Empty : File.ReadAllText(n14WebAuthPath);
string? n14ExtensionsPath = FindHostSource("MauiOpenHarmonyExtensions.cs");
string n14Extensions = n14ExtensionsPath is null ? string.Empty : File.ReadAllText(n14ExtensionsPath);
bool n14TypeOk = n14WebAuth.Contains("public sealed class OpenHarmonyWebAuthenticator : IWebAuthenticator") &&
    n14WebAuth.Contains("public static readonly OpenHarmonyWebAuthenticator Instance = new();") &&
    n14WebAuth.Contains("new Microsoft.Maui.ApplicationModel.FeatureNotSupportedException(UnsupportedMessage));") &&
    n14WebAuth.Contains("if (cancellationToken.IsCancellationRequested)") &&
    n14WebAuth.Contains("return Task.FromCanceled<WebAuthenticatorResult>(cancellationToken);");
bool n14InstallOk = n14WebAuth.Contains("[ModuleInitializer]") &&
    n14WebAuth.Contains("internal static void Initialize() => InstallDefault();") &&
    n14WebAuth.Contains("field.SetValue(null, Instance);") &&
    n14Extensions.Contains("builder.Services.AddSingleton<Microsoft.Maui.Authentication.IWebAuthenticator>(OpenHarmonyWebAuthenticator.Instance);");
bool n14WebAuthOk = n14TypeOk && n14InstallOk;
Console.WriteLine($"[verify] audit2 webauth type={n14TypeOk} install={n14InstallOk} source='{n14WebAuthPath ?? "<missing>"}' assert={n14WebAuthOk}");
if (!n14WebAuthOk)
{
    throw new InvalidOperationException($"the WebAuthenticator contract drifted: type={n14TypeOk} install={n14InstallOk}");
}

// Audit2-6: soft-input inset + ConnectionProfiles push. The host stores the shell's keyboard
// height (set/get + optional change callback the slice registers for a redraw) and parses the
// capped bearer encoding into the network-capabilities mask the managed ConnectionProfiles read;
// the shell follows avoidAreaChange/TYPE_KEYBOARD and pushes both through notifySoftInputArea /
// notifyNetworkAccess.
string? n15SafeAreaPath = FindHostSource("OpenHarmonySafeArea.cs");
string n15SafeArea = n15SafeAreaPath is null ? string.Empty : File.ReadAllText(n15SafeAreaPath);
string? n15ExtrasPath = FindHostSource("OpenHarmonyEssentialsExtras.cs");
string n15Extras = n15ExtrasPath is null ? string.Empty : File.ReadAllText(n15ExtrasPath);
bool n15SoftInputOk = n15SafeArea.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_get_soft_input_area\")]") &&
    n15SafeArea.Contains("private static extern int GetSoftInputAreaNative(out int bottom);") &&
    n15SafeArea.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_register_soft_input_change\")]") &&
    n15SafeArea.Contains("private static extern void RegisterSoftInputChangeNative(IntPtr callback);") &&
    n15SafeArea.Contains("private delegate void SoftInputChanged(int bottom);") &&
    n15SafeArea.Contains("OpenHarmonyBridge.RequestRedraw();") &&
    hSource?.Contains("void ohos_host_set_soft_input_area(int bottom);") == true &&
    hSource.Contains("int ohos_host_get_soft_input_area(int* bottom);") &&
    hSource.Contains("void ohos_host_register_soft_input_change(void* callback);") &&
    cSource?.Contains("static int g_soft_input_bottom = 0;") == true &&
    cSource.Contains("void ohos_host_set_soft_input_area(int bottom) {") &&
    cSource.Contains("if (height == g_soft_input_bottom) {") &&
    cSource.Contains("int ohos_host_get_soft_input_area(int* bottom) {") &&
    s2Napi.Contains("napi_value NotifySoftInputArea(napi_env env, napi_callback_info info) {") &&
    s2Napi.Contains("\"notifySoftInputArea\"");
bool n15ProfilesOk = n15Extras.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_network_capabilities\")]") &&
    n15Extras.Contains("private static extern int NetworkCapabilitiesNative();") &&
    n15Extras.Contains("public IEnumerable<ConnectionProfile> ConnectionProfiles") &&
    n15Extras.Contains("profiles.Add(ConnectionProfile.WiFi);") &&
    n15Extras.Contains("profiles.Add(ConnectionProfile.Cellular);") &&
    hSource?.Contains("void ohos_host_set_network_capabilities(const char* encoded);") == true &&
    hSource.Contains("int ohos_host_network_capabilities(void);") &&
    cSource?.Contains("#define OHOS_MAX_NET_BEARER_ENTRIES 8") == true &&
    cSource.Contains("void ohos_host_set_network_capabilities(const char* encoded) {") &&
    cSource.Contains("int ohos_host_network_capabilities(void) {") &&
    s2Napi.Contains("napi_value NotifyNetworkAccess(napi_env env, napi_callback_info info) {") &&
    s2Napi.Contains("ohos_host_set_network_capabilities(encoded.c_str());") &&
    s2Napi.Contains("\"notifyNetworkAccess\"");
bool n15ShellOk = true;
foreach (string n15Version in b3ShellVersions)
{
    string n15Shell = ShellSource(n15Version);
    n15ShellOk &= n15Shell.Contains("data.type === window.AvoidAreaType.TYPE_KEYBOARD") &&
        n15Shell.Contains("this.hostCall('notifySoftInputArea', typeof host !== 'undefined' && typeof host.notifySoftInputArea === 'function', (): void => {") &&
        n15Shell.Contains("host.notifySoftInputArea(height);") &&
        n15Shell.Contains("host.notifyNetworkAccess(capabilities);");
}
bool n15SoftInputProfilesOk = n15SoftInputOk && n15ProfilesOk && n15ShellOk;
Console.WriteLine($"[verify] audit2 softinput inset={n15SoftInputOk} profiles={n15ProfilesOk} shell={n15ShellOk} source='{n15SafeAreaPath ?? "<missing>"}' assert={n15SoftInputProfilesOk}");
if (!n15SoftInputProfilesOk)
{
    throw new InvalidOperationException(
        $"the soft-input/ConnectionProfiles contract drifted: inset={n15SoftInputOk} profiles={n15ProfilesOk} shell={n15ShellOk}");
}

// Audit2-7: PE2 focus hook + key surface. OpenHarmonyFocusManager replaces the shared
// ViewMapper Focus/Unfocus entries (routing the surface id through ohos_host_request_focus), and
// OpenHarmonyKeyListener registers ohos_host_register_key_event (down/up callback, no public
// MAUI key contract at rc.1); both are installed from UseOpenHarmony, the host exports are
// implemented in openharmony_host.c and consumed by the shell's onKeyEvent through host.keyEvent.
string? n16FocusPath = FindHostSource("OpenHarmonyFocusManager.cs");
string n16Focus = n16FocusPath is null ? string.Empty : File.ReadAllText(n16FocusPath);
string? n16KeyPath = FindHostSource("OpenHarmonyKeyListener.cs");
string n16Key = n16KeyPath is null ? string.Empty : File.ReadAllText(n16KeyPath);
bool n16FocusOk = n16Focus.Contains("internal static class OpenHarmonyFocusManager") &&
    n16Focus.Contains("private const string SurfaceId = \"ohos_dotnet_surface\";") &&
    n16Focus.Contains("ViewHandler.ViewCommandMapper[\"Focus\"] = OnFocusCommand;") &&
    n16Focus.Contains("ViewHandler.ViewCommandMapper[\"Unfocus\"] = OnUnfocusCommand;") &&
    n16Focus.Contains("internal static bool TryGetTargetKey(IView view, out string targetKey)");
bool n16KeyOk = n16Key.Contains("internal static class OpenHarmonyKeyListener") &&
    n16Key.Contains("internal const int KeyTypeDown = 0;") &&
    n16Key.Contains("internal const int KeyTypeUp = 1;") &&
    n16Key.Contains("private delegate void KeyEventCallback(int keyCode, int eventType);") &&
    n16Key.Contains("[DllImport(HostLibrary, EntryPoint = \"ohos_host_register_key_event\")]") &&
    n16Key.Contains("internal static void Dispatch(int keyCode, int eventType)");
bool n16HostOk = n14Extensions.Contains("OpenHarmonyFocusManager.Install();") &&
    n14Extensions.Contains("OpenHarmonyKeyListener.Install();") &&
    hSource?.Contains("void ohos_host_register_key_event(void* callback);") == true &&
    hSource.Contains("void ohos_host_key_event(int key_code, int event_type);") &&
    cSource?.Contains("void ohos_host_register_key_event(void* callback) {") == true &&
    cSource.Contains("g_app->bridge_key_event = (void (*)(int, int))callback;") &&
    cSource.Contains("void ohos_host_key_event(int key_code, int event_type) {") &&
    s2Napi.Contains("napi_value KeyEvent(napi_env env, napi_callback_info info) {") &&
    s2Napi.Contains("ohos_host_key_event(keyCode, eventType);") &&
    s2Napi.Contains("\"keyEvent\"");
bool n16ShellOk = true;
foreach (string n16Version in b3ShellVersions)
{
    string n16Shell = ShellSource(n16Version);
    n16ShellOk &= n16Shell.Contains(".onKeyEvent((event: KeyEvent): void => {") &&
        n16Shell.Contains("this.hostCall('keyEvent', typeof host !== 'undefined' && typeof host.keyEvent === 'function', (): void => {") &&
        n16Shell.Contains("host.keyEvent(event.keyCode, event.type === KeyType.Down ? 0 : 1);");
}
bool n16FocusKeysOk = n16FocusOk && n16KeyOk && n16HostOk && n16ShellOk;
Console.WriteLine($"[verify] audit2 focuskeys focus={n16FocusOk} key={n16KeyOk} host={n16HostOk} shell={n16ShellOk} source='{n16KeyPath ?? "<missing>"}' assert={n16FocusKeysOk}");
if (!n16FocusKeysOk)
{
    throw new InvalidOperationException(
        $"the PE2 focus/key contract drifted: focus={n16FocusOk} key={n16KeyOk} host={n16HostOk} shell={n16ShellOk}");
}

// Audit2-8: Shell TitleView/toolbar chrome. A visible Label title view publishes its text (a
// rich view is noted once and the page title stays in the bar), and the current page's
// ToolbarItems are mirrored into the platform bar with a tap that activates the item (guarded
// IMenuItemController). The shell handler owns one chrome instance and re-applies it per shell map.
string? n17ChromePath = FindHostSource("OpenHarmonyShellChrome.cs");
string n17Chrome = n17ChromePath is null ? string.Empty : File.ReadAllText(n17ChromePath);
string? n17ShellHandlerPath = FindHostSource("OpenHarmonyShellHandler.cs");
string n17ShellHandler = n17ShellHandlerPath is null ? string.Empty : File.ReadAllText(n17ShellHandlerPath);
bool n17TitleOk = n17Chrome.Contains("internal sealed class OpenHarmonyShellChrome") &&
    n17Chrome.Contains("public void Apply(Shell shell)") &&
    n17Chrome.Contains("_view.TitleText = ResolveTitleText(shell);") &&
    n17Chrome.Contains("View? titleView = shell.CurrentPage is { } page ? Shell.GetTitleView(page) : null;") &&
    n17Chrome.Contains("titleView ??= Shell.GetTitleView(shell);") &&
    n17Chrome.Contains("LogRichTitleViewOnce()") &&
    n17Chrome.Contains("the compositor title bar draws text only, so a rich TitleView is not rendered");
bool n17ToolbarOk = n17Chrome.Contains("UpdateToolbar(shell.CurrentPage);") &&
    n17Chrome.Contains("private void UpdateToolbar(Page? page)") &&
    n17Chrome.Contains("_view.ToolbarItems.Add((captured.Text ?? string.Empty, () => ActivateToolbarItem(captured)));") &&
    n17Chrome.Contains("private static void ActivateToolbarItem(ToolbarItem item)");
bool n17WiringOk = n17ShellHandler.Contains("private OpenHarmonyShellChrome Chrome =>") &&
    n17ShellHandler.Contains("_chrome ??= new OpenHarmonyShellChrome(PlatformView, () => OpenHarmonyBridge.RequestRedraw());") &&
    n17ShellHandler.Contains("handler.Chrome.Apply(shell);");
bool n17ChromeOk = n17TitleOk && n17ToolbarOk && n17WiringOk;
Console.WriteLine($"[verify] audit2 shellchrome title={n17TitleOk} toolbar={n17ToolbarOk} wiring={n17WiringOk} source='{n17ChromePath ?? "<missing>"}' assert={n17ChromeOk}");
if (!n17ChromeOk)
{
    throw new InvalidOperationException(
        $"the Shell TitleView/toolbar contract drifted: title={n17TitleOk} toolbar={n17ToolbarOk} wiring={n17WiringOk}");
}

// Audit2-9: PJ1/PJ2 frame-loop additions. PJ1: the animation loop (frame subscription, register/
// unregister, Pump), the scroll physics tunables + the OpenHarmonyView offset hooks, the
// scrollbars and the focus ring drawn from the platform view. PJ2: the tooltip manager replaces
// the ViewMapper "ToolTip" entry and chains the renderer present hook, and the keyboard
// accelerator manager hooks the key listener and matches tracked modifiers.
string? n18LoopPath = FindHostSource("OpenHarmonyAnimationLoop.cs");
string n18Loop = n18LoopPath is null ? string.Empty : File.ReadAllText(n18LoopPath);
string? n18PhysicsPath = FindHostSource("OpenHarmonyScrollPhysics.cs");
string n18Physics = n18PhysicsPath is null ? string.Empty : File.ReadAllText(n18PhysicsPath);
string? n18BarsPath = FindHostSource("OpenHarmonyScrollbars.cs");
string n18Bars = n18BarsPath is null ? string.Empty : File.ReadAllText(n18BarsPath);
string? n18RingPath = FindHostSource("OpenHarmonyFocusRing.cs");
string n18Ring = n18RingPath is null ? string.Empty : File.ReadAllText(n18RingPath);
string? n18ViewPath = FindHostSource("OpenHarmonyView.cs");
string n18View = n18ViewPath is null ? string.Empty : File.ReadAllText(n18ViewPath);
string? n18ToolTipPath = FindHostSource("OpenHarmonyToolTipManager.cs");
string n18ToolTip = n18ToolTipPath is null ? string.Empty : File.ReadAllText(n18ToolTipPath);
string? n18AccelPath = FindHostSource("OpenHarmonyKeyboardAcceleratorManager.cs");
string n18Accel = n18AccelPath is null ? string.Empty : File.ReadAllText(n18AccelPath);
bool n18Pj1Ok = n18Loop.Contains("internal interface IOpenHarmonyAnimation") &&
    n18Loop.Contains("internal static class OpenHarmonyAnimationLoop") &&
    n18Loop.Contains("internal static void Register(IOpenHarmonyAnimation animation)") &&
    n18Loop.Contains("private static void OnFrame(OpenHarmonyFrameEventArgs args) => Pump(NowMs, 0f);") &&
    n18Physics.Contains("internal static class OpenHarmonyScrollPhysics") &&
    n18Physics.Contains("internal const float MinFlingVelocity = 320f;") &&
    n18Physics.Contains("internal const float FrictionPerSecond = 4.5f;") &&
    n18Physics.Contains("internal const long MaxFlingMs = 4000;") &&
    n18Bars.Contains("internal static class OpenHarmonyScrollbars") &&
    n18Bars.Contains("internal const float Thickness = 4f;") &&
    n18Ring.Contains("internal static class OpenHarmonyFocusRing") &&
    n18Ring.Contains("internal const float Thickness = 3f;") &&
    n18View.Contains("OpenHarmonyScrollPhysics.OnOffsetChanged(this, horizontal: true, previous, value);") &&
    n18View.Contains("OpenHarmonyScrollPhysics.OnOffsetChanged(this, horizontal: false, previous, value);") &&
    n18View.Contains("OpenHarmonyFocusRing.Draw(canvas, this);") &&
    n18View.Contains("OpenHarmonyScrollbars.Draw(canvas, this);");
bool n18Pj2Ok = n18ToolTip.Contains("internal static class OpenHarmonyToolTipManager") &&
    n18ToolTip.Contains("internal const string MapperKey = \"ToolTip\";") &&
    n18ToolTip.Contains("internal static int ShowDelayMs { get; set; } = 650;") &&
    n18ToolTip.Contains("mapper[MapperKey] = OnToolTipMapped;") &&
    n18ToolTip.Contains("[ModuleInitializer]") &&
    n18Accel.Contains("internal static class OpenHarmonyKeyboardAcceleratorManager") &&
    n18Accel.Contains("private const int KeyCodeCtrlLeft = 2072;") &&
    n18Accel.Contains("private const int KeyCodeMetaRight = 2077;") &&
    n18Accel.Contains("internal static bool HandleKeyEvent(int keyCode, int eventType)") &&
    n18Accel.Contains("OpenHarmonyKeyListener.Install();") &&
    n18Accel.Contains("[ModuleInitializer]");
bool n18PjOk = n18Pj1Ok && n18Pj2Ok;
Console.WriteLine($"[verify] audit2 pj pj1={n18Pj1Ok} pj2={n18Pj2Ok} source='{n18ToolTipPath ?? "<missing>"}' assert={n18PjOk}");
if (!n18PjOk)
{
    throw new InvalidOperationException($"the PJ1/PJ2 contract drifted: pj1={n18Pj1Ok} pj2={n18Pj2Ok}");
}

// ---- PI1/PI2/RB pins: the newest slice surfaces with zero source-contract coverage -------------
// The PI1 real-bug fixes, the PI2 additions and the RB review-compliance artifacts are newer than
// the audit-batch-2 pins above, so each surface gets its own source contract here (one [verify]
// line per surface, parsing the committed sources in the same style as the pins above).

// PI1-1: the app-package root. FileSystem resolves packaged files against
// OpenHarmonyPaths.AppPackageDirectory (the context's AppDir = the extracted dotnet.zip payload)
// instead of the data directory, and the property falls back to the data directory when no host
// AppDir is published.
string? n19FsPath = FindHostSource("OpenHarmonyFileSystem.cs");
string n19Fs = n19FsPath is null ? string.Empty : File.ReadAllText(n19FsPath);
string? n19PathsPath = FindHostSource("OpenHarmonyPaths.cs");
string n19Paths = n19PathsPath is null ? string.Empty : File.ReadAllText(n19PathsPath);
bool n19FsOk = n19Fs.Contains("string path = Path.Combine(OpenHarmonyPaths.AppPackageDirectory, filename);") &&
    n19Fs.Contains("return Task.FromResult(File.Exists(Path.Combine(OpenHarmonyPaths.AppPackageDirectory, filename)));") &&
    n19Fs.Contains("throw new FileNotFoundException($\"App package file '{filename}' was not found.\", path);") &&
    !n19Fs.Contains("Path.Combine(OpenHarmonyPaths.DataDirectory, filename)");
bool n19PathsOk = n19Paths.Contains("public static string AppPackageDirectory") &&
    n19Paths.Contains("string? appDir = OpenHarmonyBridge.Context?.AppDir;") &&
    n19Paths.Contains("return appDir;");
bool n19AppPackageOk = n19FsOk && n19PathsOk;
Console.WriteLine($"[verify] pi1 apppackage filesystem={n19FsOk} paths={n19PathsOk} source='{n19FsPath ?? "<missing>"}' assert={n19AppPackageOk}");
if (!n19AppPackageOk)
{
    throw new InvalidOperationException(
        $"the PI1 app-package root contract drifted: fileSystem={n19FsOk} paths={n19PathsOk}");
}

// PI1-2: the shell's Create=0 send plus the host's pre-Run completion. All three shell templates
// send LIFECYCLE_CREATE (0) from both entry-ability variants and the page shell sends 0 before
// its Foreground (2); the app host records a Create that arrived before Run and completes the
// window activation when the window exists.
bool n20CreateSendOk = true;
foreach (string n20Version in b3ShellVersions)
{
    string n20Shell = ShellSource(n20Version);
    int n20IndexCreateAt = n20Shell.IndexOf("host.notifyLifecycle(0);", StringComparison.Ordinal);
    int n20IndexForegroundAt = n20Shell.IndexOf("host.notifyLifecycle(2);", StringComparison.Ordinal);
    n20CreateSendOk &= n20IndexCreateAt >= 0 && n20IndexForegroundAt > n20IndexCreateAt;
    foreach (string n20Ability in new[] { "EntryAbility.ets", "EntryAbility.ui.ets" })
    {
        string? n20AbilityPath = FindHostSource(
            $"packs/Microsoft.OpenHarmony.Sdk/{n20Version}/templates/ets/entryability/{n20Ability}");
        string n20AbilityText = n20AbilityPath is null ? string.Empty : File.ReadAllText(n20AbilityPath);
        n20CreateSendOk &= n20AbilityText.Contains("const LIFECYCLE_CREATE = 0;") &&
            n20AbilityText.Contains("host.notifyLifecycle(LIFECYCLE_CREATE);");
    }
}
bool n20HostCreateOk = n11AppHost.Contains("private bool _createReceived;") &&
    n11AppHost.Contains("_createReceived = true;") &&
    n11AppHost.Contains("if (_createReceived)\n        {\n            EnsureWindowActivated();\n        }");
bool n20CreateOk = n20CreateSendOk && n20HostCreateOk;
Console.WriteLine($"[verify] pi1 create templates={n20CreateSendOk} hostPreRun={n20HostCreateOk} source='{n11AppHostPath ?? "<missing>"}' assert={n20CreateOk}");
if (!n20CreateOk)
{
    throw new InvalidOperationException(
        $"the PI1 Create=0 / pre-Run activation contract drifted: templates={n20CreateSendOk} hostPreRun={n20HostCreateOk}");
}

// PI1-3: the CarouselView grouping flatten. CarouselView has no group concept, so a grouped
// ItemsSource (every element a collection) is materialised to its items with a one-time status
// note, and the page indicator counts the same materialised slides.
string? n21CarouselPath = FindHostSource("OpenHarmonyCarouselViewHandler.cs");
string n21Carousel = n21CarouselPath is null ? string.Empty : File.ReadAllText(n21CarouselPath);
string? n21RendererPath = FindHostSource("OpenHarmonyWindowRenderer.cs");
string n21Renderer = n21RendererPath is null ? string.Empty : File.ReadAllText(n21RendererPath);
bool n21FlattenOk = n21Carousel.Contains("internal static List<object?> MaterializeItems(ItemsView itemsView)") &&
    n21Carousel.Contains("if (items.Count == 0 || !items.All(IsGroup))") &&
    n21Carousel.Contains("OpenHarmonyStatus.Once(\"carousel.grouped\",") &&
    n21Carousel.Contains("private static bool IsGroup(object? item)") &&
    n21Carousel.Contains("=> item is System.Collections.IEnumerable && item is not string;") &&
    n21Carousel.Contains("foreach (object? item in (System.Collections.IEnumerable)group!)");
bool n21IndicatorOk = n21Renderer.Contains("int count = OpenHarmonyCarouselViewHandler.MaterializeItems(view).Count;");
bool n21CarouselOk = n21FlattenOk && n21IndicatorOk;
Console.WriteLine($"[verify] pi1 carousel flatten={n21FlattenOk} indicator={n21IndicatorOk} source='{n21CarouselPath ?? "<missing>"}' assert={n21CarouselOk}");
if (!n21CarouselOk)
{
    throw new InvalidOperationException(
        $"the PI1 carousel grouping contract drifted: flatten={n21FlattenOk} indicator={n21IndicatorOk}");
}

// PI1-4: the shadow mapper + DrawShadow. The renderer draws each platform view's IShadow through
// the host canvas shadow layer before the view content, and the ViewMapper Shadow entry (installed
// with the renderer) requests a redraw so a live shadow change repaints.
int n22ShadowAt = n21Renderer.IndexOf("platform.DrawShadow(_canvas);", StringComparison.Ordinal);
int n22DrawAt = n22ShadowAt < 0 ? -1 : n21Renderer.IndexOf("platform.Draw(_canvas);", n22ShadowAt, StringComparison.Ordinal);
bool n22DrawShadowOk = n18View.Contains("public void DrawShadow(MauiCanvas canvas)") &&
    n18View.Contains("canvas.SetShadow(new SizeF((float)shadow.Offset.X, (float)shadow.Offset.Y), shadow.Radius,") &&
    n18View.Contains("Microsoft.OpenHarmony.Hosting.OpenHarmonyCanvas.ClearEffects();") &&
    n18View.Contains("OpenHarmonyStatus.Once(\"shadow.paint.\" + (paint?.GetType().Name ?? \"null\"),");
bool n22MapperOk = n18View.Contains("internal static class OpenHarmonyShadow") &&
    n18View.Contains("mapper[nameof(IView.Shadow)] = (handler, view) =>") &&
    n18View.Contains("Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.RequestRedraw();");
bool n22RendererOk = n22ShadowAt >= 0 && n22DrawAt > n22ShadowAt && n21Renderer.Contains("OpenHarmonyShadow.Install();");
bool n22ShadowOk = n22DrawShadowOk && n22MapperOk && n22RendererOk;
Console.WriteLine($"[verify] pi1 shadow draw={n22DrawShadowOk} mapper={n22MapperOk} renderer={n22RendererOk} source='{n18ViewPath ?? "<missing>"}' assert={n22ShadowOk}");
if (!n22ShadowOk)
{
    throw new InvalidOperationException(
        $"the PI1 shadow contract drifted: draw={n22DrawShadowOk} mapper={n22MapperOk} renderer={n22RendererOk}");
}

// PI1-5: the SecureStorage file-key fallback note (reported once when HUKS is unavailable).
string? n23StoragePath = FindHostSource("OpenHarmonySecureStorage.cs");
string n23Storage = n23StoragePath is null ? string.Empty : File.ReadAllText(n23StoragePath);
bool n23StorageOk = n23Storage.Contains("OpenHarmonyStatus.Once(\"securestorage.filekey\",") &&
    n23Storage.Contains("\"secure storage is using the per-install file key: HUKS is unavailable, values are obfuscated but not hardware-backed\");");
Console.WriteLine($"[verify] pi1 securestorage fallbackNote={n23StorageOk} source='{n23StoragePath ?? "<missing>"}' assert={n23StorageOk}");
if (!n23StorageOk)
{
    throw new InvalidOperationException("the PI1 SecureStorage file-key fallback note contract drifted");
}

// PI2-1: the platform application object. UseOpenHarmony registers OpenHarmonyMauiApplication plus
// the IMauiInitializeService shim, and the application publishes IPlatformApplication.Current from
// its constructor (MauiAppBuilder.Build runs the initializer before the host's Run).
string? n24ApplicationPath = FindHostSource("OpenHarmonyMauiApplication.cs");
string n24Application = n24ApplicationPath is null ? string.Empty : File.ReadAllText(n24ApplicationPath);
bool n24InstallOk = n14Extensions.Contains("builder.Services.AddSingleton<OpenHarmonyMauiApplication>();") &&
    n14Extensions.Contains("builder.Services.AddSingleton<Microsoft.Maui.Hosting.IMauiInitializeService, OpenHarmonyMauiApplicationInitializer>();");
bool n24ApplicationOk = n24Application.Contains("public sealed class OpenHarmonyMauiApplication : IPlatformApplication") &&
    n24Application.Contains("IPlatformApplication.Current = this;") &&
    n24Application.Contains("public static OpenHarmonyMauiApplication? Instance { get; private set; }") &&
    n24Application.Contains("internal sealed class OpenHarmonyMauiApplicationInitializer : IMauiInitializeService") &&
    n24Application.Contains("_ = services.GetRequiredService<OpenHarmonyMauiApplication>();") &&
    n24Application.Contains("OpenHarmonyWindowOverlayHost.Install();");
bool n24AppObjectOk = n24InstallOk && n24ApplicationOk;
Console.WriteLine($"[verify] pi2 appobject install={n24InstallOk} application={n24ApplicationOk} source='{n24ApplicationPath ?? "<missing>"}' assert={n24AppObjectOk}");
if (!n24AppObjectOk)
{
    throw new InvalidOperationException(
        $"the PI2 platform-application contract drifted: install={n24InstallOk} application={n24ApplicationOk}");
}

// PI2-2: the window-overlay host. The host chains the renderer's existing SurfacePresent seam
// (draw the visible, initialized overlays, then the previous hook or the hosting present), and
// OpenHarmonyWindowOverlay registers/unregisters through Initialize/Deinitialize.
string? n25OverlayPath = FindHostSource("OpenHarmonyWindowOverlay.cs");
string n25Overlay = n25OverlayPath is null ? string.Empty : File.ReadAllText(n25OverlayPath);
bool n25OverlayClassOk = n25Overlay.Contains("public class OpenHarmonyWindowOverlay : IWindowOverlay") &&
    n25Overlay.Contains("OpenHarmonyWindowOverlayHost.Register(this);") &&
    n25Overlay.Contains("OpenHarmonyWindowOverlayHost.Unregister(this);");
bool n25ChainOk = n25Overlay.Contains("internal static class OpenHarmonyWindowOverlayHost") &&
    n25Overlay.Contains("s_presentPrevious = OpenHarmonyWindowRenderer.SurfacePresent;") &&
    n25Overlay.Contains("OpenHarmonyWindowRenderer.SurfacePresent = s_presentDelegate;") &&
    n25Overlay.Contains("s_presentPrevious is { } previous") &&
    n25Overlay.Contains("HostCanvas.Present();");
bool n25OverlayDrawOk = n25Overlay.Contains("overlay.Draw(canvas, rect);") && n25Overlay.Contains("Draws++;");
bool n25OverlayOk = n25OverlayClassOk && n25ChainOk && n25OverlayDrawOk;
Console.WriteLine($"[verify] pi2 overlay class={n25OverlayClassOk} chain={n25ChainOk} draw={n25OverlayDrawOk} source='{n25OverlayPath ?? "<missing>"}' assert={n25OverlayOk}");
if (!n25OverlayOk)
{
    throw new InvalidOperationException(
        $"the PI2 window-overlay contract drifted: class={n25OverlayClassOk} chain={n25ChainOk} draw={n25OverlayDrawOk}");
}

// RB-1: the OpenHarmony TFM gating. MultiTargeting.targets removes the slice for every
// non-OpenHarmony TFM and defines OPENHARMONY for the OpenHarmony TFM; Core.csproj wires the
// graphics-backend reference the ref pack does not carry inside the OpenHarmony-only block.
string? n26MultiPath = FindHostSource("src/MultiTargeting.targets");
string n26Multi = n26MultiPath is null ? string.Empty : File.ReadAllText(n26MultiPath);
string? n26CorePath = FindHostSource("src/Core/src/Core.csproj");
string n26Core = n26CorePath is null ? string.Empty : File.ReadAllText(n26CorePath);
bool n26RemoveOk = n26Multi.Contains("<ItemGroup Condition=\" '$(_MauiTargetPlatformIsOpenHarmony)' != 'True' \">") &&
    n26Multi.Contains("<Compile Remove=\"**\\OpenHarmony\\**\\*.cs\" />") &&
    n26Multi.Contains("<None Include=\"**\\OpenHarmony\\**\\*.cs\" Exclude=\"$(DefaultItemExcludes);$(DefaultExcludesInProjectFolder)\" />");
bool n26DefineOk = n26Multi.Contains("<PropertyGroup Condition=\" '$(_MauiTargetPlatformIsOpenHarmony)' == 'True' \">") &&
    n26Multi.Contains("<DefineConstants>$(DefineConstants);OPENHARMONY</DefineConstants>");
bool n26CoreOk = n26Core.Contains("<PropertyGroup Condition=\"$(TargetFramework.Contains('-openharmony'))\">") &&
    n26Core.Contains("<OpenHarmonyGraphicsAssembly Condition=\" '$(OpenHarmonyGraphicsAssembly)' == '' \">") &&
    n26Core.Contains("<Reference Include=\"Microsoft.OpenHarmony.Maui.Graphics\">");
bool n26TfmOk = n26RemoveOk && n26DefineOk && n26CoreOk;
Console.WriteLine($"[verify] rb tfm remove={n26RemoveOk} define={n26DefineOk} core={n26CoreOk} source='{n26MultiPath ?? "<missing>"}' assert={n26TfmOk}");
if (!n26TfmOk)
{
    throw new InvalidOperationException(
        $"the RB TFM-gating contract drifted: remove={n26RemoveOk} define={n26DefineOk} core={n26CoreOk}");
}

// RB-2: the net-openharmony public API baseline exists with its header and carries the PI2 types.
string? n27ShippedPath = FindHostSource("src/Core/src/PublicAPI/net-openharmony/PublicAPI.Shipped.txt");
string? n27UnshippedPath = FindHostSource("src/Core/src/PublicAPI/net-openharmony/PublicAPI.Unshipped.txt");
string n27Shipped = n27ShippedPath is null ? string.Empty : File.ReadAllText(n27ShippedPath);
string n27Unshipped = n27UnshippedPath is null ? string.Empty : File.ReadAllText(n27UnshippedPath);
bool n27ExistsOk = n27ShippedPath is not null && n27UnshippedPath is not null &&
    n27Shipped.StartsWith("#nullable enable", StringComparison.Ordinal) &&
    n27Unshipped.StartsWith("#nullable enable", StringComparison.Ordinal);
bool n27SurfaceOk = n27Unshipped.Contains("Microsoft.Maui.Platform.OpenHarmonyMauiApplication") &&
    n27Unshipped.Contains("Microsoft.Maui.Platform.OpenHarmonyWindowOverlay");
bool n27ApiOk = n27ExistsOk && n27SurfaceOk;
Console.WriteLine($"[verify] rb publicapi exists={n27ExistsOk} surface={n27SurfaceOk} source='{n27UnshippedPath ?? "<missing>"}' assert={n27ApiOk}");
if (!n27ApiOk)
{
    throw new InvalidOperationException(
        $"the RB public-API baseline contract drifted: exists={n27ExistsOk} surface={n27SurfaceOk}");
}

// RB-3: the SupportedPlatform declaration in this repository's Directory.Build.props (the CA1418
// fix: one declaration for every project instead of per-project NoWarn suppressions). The
// declaration lives in the *repository root* props; the plain name resolves to the nearest
// Directory.Build.props, which is the test tree's (test/Directory.Build.props), so anchor the
// lookup on the repository-root marker instead.
string? n28PreflightPath = FindHostSource("scripts/preflight.sh");
string? n28PropsPath = n28PreflightPath is null
    ? null
    : Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(n28PreflightPath)!)!, "Directory.Build.props");
string n28Props = n28PropsPath is not null && File.Exists(n28PropsPath) ? File.ReadAllText(n28PropsPath) : string.Empty;
bool n28PropsOk = n28Props.Contains("<SupportedPlatform Include=\"openharmony\" />") &&
    n28Props.Contains("it once for every project (the SDK's SupportedPlatform pattern)");
Console.WriteLine($"[verify] rb supportedplatform declared={n28PropsOk} source='{n28PropsPath ?? "<missing>"}' assert={n28PropsOk}");
if (!n28PropsOk)
{
    throw new InvalidOperationException("the RB SupportedPlatform declaration contract drifted");
}

// RB-4: the frozen native ABI comment in the slice's standalone csproj.
string? n29SlicePath = FindHostSource("Microsoft.Maui.Platform.OpenHarmony.csproj");
string n29Slice = n29SlicePath is null ? string.Empty : File.ReadAllText(n29SlicePath);
bool n29FreezeOk = n29Slice.Contains("ABI freeze (R5):") &&
    n29Slice.Contains("frozen compatibility surface") &&
    n29Slice.Contains("ohos_host_*") &&
    n29Slice.Contains("OHOS_HOST_APP_CONTEXT");
Console.WriteLine($"[verify] rb frozenabi comment={n29FreezeOk} source='{n29SlicePath ?? "<missing>"}' assert={n29FreezeOk}");
if (!n29FreezeOk)
{
    throw new InvalidOperationException("the RB frozen-ABI comment contract drifted");
}

// ---- PG2: packaging/host invariants (staged runtime libs, libc++, bridge, host guard) ----------
// The "runtime natives ship only in the signed libs/<abi>/" increment relies on four invariants
// that this section pins to the committed sources, so a regression fails this off-device run
// instead of shipping a pack built from drifted files:
//   * the preview.22/23/24 hap staging enumerates the publish payload's *.so files, validates the
//     ELF magic, copies them into libs/<abi>/ (skipping the host and libc++_shared.so the SDK
//     already staged) and exposes the copied set as the _OpenHarmonyStagedRuntimeLib item, with a
//     hard error when the set is empty; the deterministic zip receives exactly that set through
//     ExcludeFileNames (@(...->'%(Filename)%(Extension)')) and drops the names before packing;
//   * the staged libs are re-signed in place by the shared ElfSigner task, and the libc++_shared
//     staging keeps its SDK root/OHOS_NDK lookup, the explicit override and the missing error;
//   * openharmony_host.c bridges the signed libs/<abi>/ runtime natives into app_dir (symlink,
//     copy fallback, one summary log) on both launch paths before hostfxr is initialized;
//   * scripts/build-host.sh fails the build when libhostfxr appears in DT_NEEDED, before signing.

// PG2a: runtime-native staging + the dotnet.zip exclusion (the three packs stay byte-identical).
string[] pg2PackVersions = { "1.0.0-preview.22", "1.0.0-preview.23", "1.0.0-preview.24" };
bool pg2StageOk = true;
bool pg2StageElfOk = true;
bool pg2ZipOk = true;
bool pg2StageOrderOk = true;
bool pg2PackIdentical = true;
string? pg2PackPath = null;
string pg2PackFirst = string.Empty;
foreach (string pg2Version in pg2PackVersions)
{
    string? pg2Path = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{pg2Version}/targets/OpenHarmony.Hap.targets");
    pg2PackPath ??= pg2Path;
    string pg2Text = pg2Path is null ? string.Empty : File.ReadAllText(pg2Path);
    if (pg2PackFirst.Length == 0)
    {
        pg2PackFirst = pg2Text;
    }
    pg2PackIdentical &= pg2Text == pg2PackFirst;
    int pg2StageAt = pg2Text.IndexOf("<OpenHarmonyStageRuntimeLibs SourceFiles=", StringComparison.Ordinal);
    int pg2CodesignAt = pg2Text.IndexOf("<OpenHarmonyCodesign Directories=\"$(_OpenHarmonyHapStageDir)libs\" />", StringComparison.Ordinal);
    int pg2ZipAt = pg2Text.IndexOf("<OpenHarmonyDeterministicZip", StringComparison.Ordinal);
    int pg2ExcludeAt = pg2Text.IndexOf("ExcludeFileNames=\"@(_OpenHarmonyStagedRuntimeLib->'%(Filename)%(Extension)')\"", StringComparison.Ordinal);
    pg2StageOk &= pg2Text.Contains("<_OpenHarmonyPayloadNativeLib Include=\"$(_OpenHarmonyRuntimePublishDir)*.so\" />") &&
        pg2Text.Contains("DestinationDirectory=\"$(_OpenHarmonyHapStageDir)libs/$(OpenHarmonyAbi)\"") &&
        pg2Text.Contains("SkipFileNames=\"libopenharmonyhost.so;libc++_shared.so\"") &&
        pg2Text.Contains("<Output TaskParameter=\"CopiedFiles\" ItemName=\"_OpenHarmonyStagedRuntimeLib\" />") &&
        pg2Text.Contains("<Output TaskParameter=\"CopiedCount\" PropertyName=\"_OpenHarmonyStagedRuntimeLibCount\" />") &&
        pg2Text.Contains("<Output TaskParameter=\"CopiedBytes\" PropertyName=\"_OpenHarmonyStagedRuntimeLibBytes\" />") &&
        pg2Text.Contains("<Error Condition=\" '$(_OpenHarmonyStagedRuntimeLibCount)' == '0' or '$(_OpenHarmonyStagedRuntimeLibCount)' == '' \"") &&
        pg2Text.Contains("no ELF runtime library (*.so) found in the publish payload");
    pg2StageElfOk &= pg2Text.Contains("return magic[0] == 0x7F && magic[1] == (byte)'E' && magic[2] == (byte)'L' && magic[3] == (byte)'F';") &&
        pg2Text.Contains("OpenHarmony runtime libs: skipping non-ELF");
    pg2ZipOk &= pg2Text.Contains("<ExcludeFileNames ParameterType=\"System.String\" />") &&
        pg2Text.Contains("if (exclude.Contains(System.IO.Path.GetFileName(file)))") &&
        pg2Text.Contains("ExcludedCount++;") &&
        pg2Text.Contains("runtime native libraries that ship in libs/$(OpenHarmonyAbi)/ only");
    pg2StageOrderOk &= pg2StageAt >= 0 && pg2CodesignAt > pg2StageAt && pg2ZipAt > pg2CodesignAt &&
        pg2ExcludeAt > pg2ZipAt && pg2Text.Contains("excluded from dotnet.zip");
}
bool pg2PackOk = pg2StageOk && pg2StageElfOk && pg2ZipOk && pg2StageOrderOk && pg2PackIdentical;
Console.WriteLine($"[verify] pg2 pack runtime libs packs=22,23,24 staged={pg2StageOk} elf={pg2StageElfOk} excluded={pg2ZipOk} order={pg2StageOrderOk} identical={pg2PackIdentical} source='{pg2PackPath ?? "<missing>"}' assert={pg2PackOk}");
if (!pg2PackOk)
{
    throw new InvalidOperationException(
        $"the PG2 runtime-native staging / dotnet.zip exclusion contract drifted: staged={pg2StageOk} " +
        $"elf={pg2StageElfOk} excluded={pg2ZipOk} order={pg2StageOrderOk} identical={pg2PackIdentical} " +
        $"source={pg2PackPath ?? "<missing>"}");
}

// PG2b: the libc++_shared.so staging and the staged-libs re-sign pass (all three packs).
bool pg2LibcxxLookupOk = true;
bool pg2LibcxxErrorsOk = true;
bool pg2LibcxxCopyOk = true;
bool pg2ResignOk = true;
string? pg2LibcxxPath = null;
foreach (string pg2Version in pg2PackVersions)
{
    string? pg2Path = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{pg2Version}/targets/OpenHarmony.Hap.targets");
    pg2LibcxxPath ??= pg2Path;
    string pg2Text = pg2Path is null ? string.Empty : File.ReadAllText(pg2Path);
    pg2LibcxxLookupOk &= pg2Text.Contains("<_OpenHarmonyNativeAbi Condition=\" '$(OpenHarmonyAbi)' == 'arm64-v8a' \">aarch64-linux-ohos</_OpenHarmonyNativeAbi>") &&
        !pg2Text.Contains("harmonybrew/Cellar") &&
        !pg2Text.Contains("GetEnvironmentVariable('HOME')") &&
        pg2Text.Contains("Set OpenHarmonySdkRoot (or OHOS_SDK_ROOT) to the SDK root that contains toolchains/lib") &&
        pg2Text.Contains("<_OpenHarmonyLibCxxShared Condition=\" '$(_OpenHarmonyNdkRootDir)' != '' and Exists('$(_OpenHarmonyNdkRootDir)llvm/lib/$(_OpenHarmonyNativeAbi)/libc++_shared.so') \"") &&
        pg2Text.Contains("<_OpenHarmonyLibCxxShared Condition=\" '$(OpenHarmonyLibCxxShared)' != '' \" Include=\"$(OpenHarmonyLibCxxShared)\" />");
    pg2LibcxxErrorsOk &= pg2Text.Contains("<Error Condition=\" '$(OpenHarmonyLibCxxShared)' != '' and !Exists('$(OpenHarmonyLibCxxShared)') \"") &&
        pg2Text.Contains("libc++_shared.so was not found; libopenharmonyhost.so requires it at runtime");
    pg2LibcxxCopyOk &= pg2Text.Contains("<Copy SourceFiles=\"@(_OpenHarmonyLibCxxShared)\" DestinationFolder=\"$(_OpenHarmonyHapStageDir)libs/$(OpenHarmonyAbi)/\" />") &&
        pg2Text.Contains("OpenHarmony: staged libc++_shared.so from @(_OpenHarmonyLibCxxShared->'%(Identity)', '; ')");
    pg2ResignOk &= pg2Text.Contains("<OpenHarmonyCodesign Directories=\"$(_OpenHarmonyHapStageDir)libs\" />") &&
        pg2Text.Contains("a vendor .codesign that is not the ElfSigner format") &&
        pg2Text.Contains("the ElfSigner task assembly '$(MicrosoftNETBuildTasksAssembly)' was not found");
}
bool pg2LibcxxOk = pg2LibcxxLookupOk && pg2LibcxxErrorsOk && pg2LibcxxCopyOk && pg2ResignOk;
Console.WriteLine($"[verify] pg2 pack libcxx staging lookup={pg2LibcxxLookupOk} errors={pg2LibcxxErrorsOk} copy={pg2LibcxxCopyOk} resign={pg2ResignOk} packs=22,23,24 source='{pg2LibcxxPath ?? "<missing>"}' assert={pg2LibcxxOk}");
if (!pg2LibcxxOk)
{
    throw new InvalidOperationException(
        $"the PG2 libc++_shared staging / re-sign contract drifted: lookup={pg2LibcxxLookupOk} " +
        $"errors={pg2LibcxxErrorsOk} copy={pg2LibcxxCopyOk} resign={pg2ResignOk} " +
        $"source={pg2LibcxxPath ?? "<missing>"}");
}

// PG2b2: the pack target contracts added by the audit follow-up: the JSON-aware module.json
// task (no ReadLinesFromFile line contract), the @(StaticWebAsset)-only Blazor staging (no
// NuGet-cache glob), the FileWrites registration of every created artifact, and the
// OpenHarmonyAfterPublishDependsOn hook on the AfterTargets=Publish staging target.
bool pg2ModuleJsonOk = true;
bool pg2BlazorOk = true;
bool pg2FileWritesOk = true;
bool pg2HookOk = true;
string? pg2ContractsPath = null;
foreach (string pg2Version in pg2PackVersions)
{
    string? pg2Path = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{pg2Version}/targets/OpenHarmony.Hap.targets");
    pg2ContractsPath ??= pg2Path;
    string pg2Text = pg2Path is null ? string.Empty : File.ReadAllText(pg2Path);
    pg2ModuleJsonOk &= pg2Text.Contains("<UsingTask TaskName=\"OpenHarmonyGenerateModuleJson\"") &&
        pg2Text.Contains("class OpenHarmonyGenerateModuleJson") &&
        pg2Text.Contains("IsJsonLiteral") &&
        pg2Text.Contains("EscapeJsonString") &&
        !pg2Text.Contains("<ReadLinesFromFile File=\"$(_OpenHarmonyTemplatesDir)module.json.template\">") &&
        pg2Text.Contains("<OpenHarmonyGenerateModuleJson TemplateFile=\"$(_OpenHarmonyTemplatesDir)module.json.template\"") &&
        pg2Text.Contains("ExtraPermissions=\"@(_OpenHarmonyModuleJsonPermission)\"");
    pg2BlazorOk &= pg2Text.Contains("the project carries wwwroot content but @(StaticWebAsset) has no blazor.webview.js") &&
        !pg2Text.Contains("$(NuGetPackageRoot)microsoft.aspnetcore.components.webview") &&
        !pg2Text.Contains("blazor.webview.js was not found in @(StaticWebAsset)");
    pg2FileWritesOk &= pg2Text.Contains("<FileWrites Include=\"$(_OpenHarmonyHapStageDir)**/*\" />") &&
        pg2Text.Contains("<FileWrites Include=\"$(_OpenHarmonyResourceIndexDir)**/*\" />") &&
        pg2Text.Contains("<FileWrites Include=\"$(_OpenHarmonyHapUnsigned)\" />") &&
        pg2Text.Contains("<FileWrites Include=\"$(_OpenHarmonyHapFile)\" />");
    pg2HookOk &= pg2Text.Contains("AfterTargets=\"Publish\"") &&
        pg2Text.Contains("DependsOnTargets=\"$(OpenHarmonyAfterPublishDependsOn);_OpenHarmonyDetectToolchain;");
}
bool pg2ContractsOk = pg2ModuleJsonOk && pg2BlazorOk && pg2FileWritesOk && pg2HookOk;
Console.WriteLine($"[verify] pg2 pack contracts moduleJson={pg2ModuleJsonOk} blazorStatic={pg2BlazorOk} fileWrites={pg2FileWritesOk} afterPublishHook={pg2HookOk} packs=22,23,24 source='{pg2ContractsPath ?? "<missing>"}' assert={pg2ContractsOk}");
if (!pg2ContractsOk)
{
    throw new InvalidOperationException(
        $"the PG2 module.json / Blazor / FileWrites / AfterPublish contracts drifted: " +
        $"moduleJson={pg2ModuleJsonOk} blazorStatic={pg2BlazorOk} fileWrites={pg2FileWritesOk} " +
        $"afterPublishHook={pg2HookOk} source={pg2ContractsPath ?? "<missing>"}");
}

// PG2c: the host's runtime-lib bridge (openharmony_host.c). The bridge runs on both launch paths
// before hostfxr is initialized, resolves its own signed libs directory through dladdr, links the
// runtime natives into the effective app_dir (the caller's, or the staged libs/<abi>/ directory
// the payload-in-libs resolution claims; skipped then) with a copy fallback (warned once), and
// logs one summary line.
int pg2RunAt = cSource?.IndexOf("int ohos_host_run_app(const char* app_dir", StringComparison.Ordinal) ?? -1;
int pg2RunBridgeAt = pg2RunAt < 0 ? -1 : cSource!.IndexOf("OhosHostEnsureRuntimeLibs(\"run_app\", effective_app_dir);", pg2RunAt, StringComparison.Ordinal);
int pg2RunHostfxrAt = pg2RunBridgeAt < 0 ? -1 : cSource!.IndexOf("OhosHostOpenHostfxr(\"run_app\"", pg2RunBridgeAt, StringComparison.Ordinal);
int pg2StartAt = cSource?.IndexOf("int ohos_host_start_app(const char* app_dir", StringComparison.Ordinal) ?? -1;
int pg2StartBridgeAt = pg2StartAt < 0 ? -1 : cSource!.IndexOf("OhosHostEnsureRuntimeLibs(\"start_app\", effective_app_dir);", pg2StartAt, StringComparison.Ordinal);
int pg2StartHostfxrAt = pg2StartBridgeAt < 0 ? -1 : cSource!.IndexOf("OhosHostOpenHostfxr(\"start_app\"", pg2StartBridgeAt, StringComparison.Ordinal);
bool pg2BridgeDefOk = cSource?.Contains("static void OhosHostEnsureRuntimeLibs(const char* caller, const char* app_dir) {") == true;
bool pg2BridgePathsOk = pg2RunAt >= 0 && pg2RunBridgeAt > pg2RunAt && pg2RunHostfxrAt > pg2RunBridgeAt &&
    pg2StartAt >= 0 && pg2StartBridgeAt > pg2StartAt && pg2StartHostfxrAt > pg2StartBridgeAt;
bool pg2BridgeDladdrOk = cSource?.Contains("static int OhosHostOwnDirectory(char* dir, size_t dir_size) {") == true &&
    cSource!.Contains("dladdr((void*)&ohos_host_run_app, &own_info) == 0") &&
    cSource.Contains("OhosHostOwnDirectory(libs_dir, sizeof(libs_dir)) != 0");
bool pg2BridgeLinkOk = cSource?.Contains("if (symlink(src, dst) == 0) {") == true &&
    cSource!.Contains("static int OhosHostRuntimeLibCopy(const char* src, const char* dst) {") &&
    cSource.Contains("if (OhosHostRuntimeLibCopy(src, dst) == 0) {") &&
    cSource.Contains("static int g_runtime_lib_copy_warned = 0;") &&
    cSource.Contains("if (!g_runtime_lib_copy_warned) {") &&
    cSource.Contains("the copy is not covered by the HAP signing block");
bool pg2BridgeSummaryOk = cSource?.Contains("runtime lib bridge in %s: %d ensured, %d copied, %d failed ") == true &&
    cSource!.Contains("%{public}d ensured, %{public}d copied, %{public}d failed") &&
    cSource.Contains("(last %s errno=%d)\\n");
bool pg2BridgeFilterOk = cSource?.Contains("\"libhostfxr.\", \"libhostpolicy.\", \"libcoreclr.\", \"libclrjit.\", \"libclrgc.\", \"libclrgcexp.\",") == true &&
    cSource!.Contains("\"libmscordaccore.\", \"libmscordbi.\", \"libSystem.\",") &&
    cSource.Contains("#define OHOS_RUNTIME_LIB_SCAN_MAX 256") &&
    cSource.Contains("#define OHOS_RUNTIME_LIB_LINK_MAX 64") &&
    cSource.Contains("// PF4-LIB-BRIDGE-BEGIN:") && cSource.Contains("// PF4-LIB-BRIDGE-END");
bool pg2BridgeOk = pg2BridgeDefOk && pg2BridgePathsOk && pg2BridgeDladdrOk && pg2BridgeLinkOk &&
    pg2BridgeSummaryOk && pg2BridgeFilterOk;
Console.WriteLine($"[verify] pg2 host runtime bridge defined={pg2BridgeDefOk} bothPaths={pg2BridgePathsOk} dladdr={pg2BridgeDladdrOk} symlinkCopy={pg2BridgeLinkOk} summary={pg2BridgeSummaryOk} filter={pg2BridgeFilterOk} source='{cSourcePath ?? "<missing>"}' assert={pg2BridgeOk}");
if (!pg2BridgeOk)
{
    throw new InvalidOperationException(
        $"the PG2 host runtime-lib bridge contract drifted: defined={pg2BridgeDefOk} paths={pg2BridgePathsOk} " +
        $"dladdr={pg2BridgeDladdrOk} symlinkCopy={pg2BridgeLinkOk} summary={pg2BridgeSummaryOk} " +
        $"filter={pg2BridgeFilterOk} source={cSourcePath ?? "<missing>"}");
}

// PG2d: the host build's DT_NEEDED guard (scripts/build-host.sh): the readelf lookup, the
// libhostfxr NEEDED failure with its exit 1, and the guard's position after the link and before
// the self-sign pass.
string? pg2HostScriptPath = FindHostSource("scripts/build-host.sh");
string pg2HostScript = pg2HostScriptPath is null ? string.Empty : File.ReadAllText(pg2HostScriptPath);
int pg2ReadelfGuardAt = pg2HostScript.IndexOf("if \"$READELF\" -d \"$OUT/libopenharmonyhost.so\" 2>/dev/null | grep -q 'libhostfxr'; then", StringComparison.Ordinal);
int pg2LinkAt = pg2HostScript.IndexOf("--ld-path=\"$LLD\"", StringComparison.Ordinal);
int pg2SelfsignAt = pg2HostScript.IndexOf("selfsign.sh\" \"$OUT/libopenharmonyhost.so\"", StringComparison.Ordinal);
bool pg2GuardReadelfOk = pg2HostScript.Contains("READELF=\"${READELF:-$NATIVE/llvm/bin/llvm-readelf}\"") &&
    pg2HostScript.Contains("READELF=\"$(command -v readelf || true)\"") &&
    pg2HostScript.Contains("[ -n \"$READELF\" ] || { echo \"ERROR: no llvm-readelf/readelf found to audit DT_NEEDED\" >&2; exit 1; }");
bool pg2GuardFailOk = pg2ReadelfGuardAt > 0 &&
    pg2HostScript.IndexOf("ERROR: libopenharmonyhost.so has DT_NEEDED libhostfxr.so; drop the -lhostfxr link flag", pg2ReadelfGuardAt, StringComparison.Ordinal) > pg2ReadelfGuardAt &&
    pg2HostScript.IndexOf("route every hostfxr_* call through the existing dlopen/dlsym handle", pg2ReadelfGuardAt, StringComparison.Ordinal) > pg2ReadelfGuardAt &&
    pg2HostScript.IndexOf("exit 1\nfi", pg2ReadelfGuardAt, StringComparison.Ordinal) > pg2ReadelfGuardAt;
bool pg2GuardOrderOk = pg2LinkAt >= 0 && pg2ReadelfGuardAt > pg2LinkAt && pg2SelfsignAt > pg2ReadelfGuardAt;
bool pg2GuardEvidenceOk = pg2HostScript.Contains("DT_NEEDED (libhostfxr must be absent; all others SDK/system-provided)") &&
    pg2HostScript.Contains("the host must carry NO DT_NEEDED on libhostfxr.so");
bool pg2GuardOk = pg2GuardReadelfOk && pg2GuardFailOk && pg2GuardOrderOk && pg2GuardEvidenceOk;
Console.WriteLine($"[verify] pg2 build-host guard readelf={pg2GuardReadelfOk} fail={pg2GuardFailOk} order={pg2GuardOrderOk} evidence={pg2GuardEvidenceOk} source='{pg2HostScriptPath ?? "<missing>"}' assert={pg2GuardOk}");
if (!pg2GuardOk)
{
    throw new InvalidOperationException(
        $"the PG2 build-host DT_NEEDED guard drifted: readelf={pg2GuardReadelfOk} fail={pg2GuardFailOk} " +
        $"order={pg2GuardOrderOk} evidence={pg2GuardEvidenceOk} source={pg2HostScriptPath ?? "<missing>"}");
}

// PG2e: the payload-in-libs app_dir resolution (openharmony_host.c): OhosHostResolveAppDir
// prefers this library's own libs/<abi>/ directory when the entry assembly is staged there, so
// both launch paths resolve the effective directory - and the runtime-lib bridge above only
// runs for the caller's directory - before anything else touches app_dir.
bool pg2ResolveDefOk = cSource?.Contains("static const char* OhosHostResolveAppDir(const char* caller, const char* app_dir,") == true;
int pg2ResolveRunAt = pg2RunAt < 0 ? -1 : cSource!.IndexOf("OhosHostResolveAppDir(\"run_app\", app_dir, app_assembly_file, own_dir, sizeof(own_dir), &used_own);", pg2RunAt, StringComparison.Ordinal);
int pg2ResolveStartAt = pg2StartAt < 0 ? -1 : cSource!.IndexOf("OhosHostResolveAppDir(\"start_app\", app_dir, app_assembly_file, own_dir, sizeof(own_dir), &used_own);", pg2StartAt, StringComparison.Ordinal);
bool pg2ResolvePathsOk = pg2ResolveRunAt > pg2RunAt && pg2ResolveRunAt < pg2RunBridgeAt &&
    pg2ResolveStartAt > pg2StartAt && pg2ResolveStartAt < pg2StartBridgeAt;
bool pg2ResolveOk = pg2ResolveDefOk && pg2ResolvePathsOk;
Console.WriteLine($"[verify] pg2 host resolve app dir defined={pg2ResolveDefOk} runPath={pg2ResolveRunAt > pg2RunAt} startPath={pg2ResolveStartAt > pg2StartAt} beforeBridge={pg2ResolvePathsOk} source='{cSourcePath ?? "<missing>"}' assert={pg2ResolveOk}");
if (!pg2ResolveOk)
{
    throw new InvalidOperationException(
        $"the PG2 payload-in-libs app_dir resolution drifted: defined={pg2ResolveDefOk} " +
        $"runPath={pg2ResolveRunAt > pg2RunAt} startPath={pg2ResolveStartAt > pg2StartAt} " +
        $"beforeBridge={pg2ResolvePathsOk} source={cSourcePath ?? "<missing>"}");
}

// PG2f: the resolution log the device keys on: hilog plus the stderr mirror, carrying the
// used_own=0|1 own=<own dir> app=<effective dir> markers.
bool pg2ResolveLogOk = cSource?.Contains("\"[openharmony-host] %{public}s: app_dir resolution: used_own=%{public}d own=%{public}s app=%{public}s\"") == true &&
    cSource!.Contains("fprintf(stderr, \"[openharmony-host] %s: app_dir resolution: used_own=%d own=%s app=%s\\n\"");
Console.WriteLine($"[verify] pg2 host resolve app dir log hilog={cSource?.Contains("\"[openharmony-host] %{public}s: app_dir resolution: used_own=%{public}d own=%{public}s app=%{public}s\"") == true} stderr={cSource?.Contains("fprintf(stderr, \"[openharmony-host] %s: app_dir resolution: used_own=%d own=%s app=%s\\n\"") == true} source='{cSourcePath ?? "<missing>"}' assert={pg2ResolveLogOk}");
if (!pg2ResolveLogOk)
{
    throw new InvalidOperationException(
        $"the PG2 app_dir resolution log drifted (<used_own=0|1 own=... app=...> markers): source={cSourcePath ?? "<missing>"}");
}

// PG2g: the .dotnet-payload.json marker contract, cross-file like the pack pins above: the
// three preview packs write the marker (MarkerFileName, the libs entry count, the
// payloadEntries/zipEntries staging counters and the packed fallback zipSha256) and both
// entry-ability templates read it back through PAYLOAD_MARKER_NAME/PayloadMarker.
bool pg2MarkerTargetsOk = true;
bool pg2MarkerShellOk = true;
string? pg2MarkerPath = null;
foreach (string pg2Version in pg2PackVersions)
{
    string? pg2TargetsPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{pg2Version}/targets/OpenHarmony.Hap.targets");
    pg2MarkerPath ??= pg2TargetsPath;
    string pg2Targets = pg2TargetsPath is null ? string.Empty : File.ReadAllText(pg2TargetsPath);
    pg2MarkerTargetsOk &= pg2Targets.Contains("MarkerFileName=\".dotnet-payload.json\"") &&
        pg2Targets.Contains("json.Append(\",\\\"payloadEntries\\\":\").Append(PayloadEntries);") &&
        pg2Targets.Contains("json.Append(\",\\\"zipEntries\\\":\").Append(ZipEntries);") &&
        pg2Targets.Contains("json.Append(\",\\\"zipSha256\\\":\\\"\").Append(zipSha).Append('\"');");
    foreach (string pg2ShellName in new[] { "EntryAbility.ets", "EntryAbility.ui.ets" })
    {
        string? pg2ShellPath = FindHostSource($"packs/Microsoft.OpenHarmony.Sdk/{pg2Version}/templates/ets/entryability/{pg2ShellName}");
        string pg2Shell = pg2ShellPath is null ? string.Empty : File.ReadAllText(pg2ShellPath);
        pg2MarkerShellOk &= pg2Shell.Contains("const PAYLOAD_MARKER_NAME = '.dotnet-payload.json';") &&
            pg2Shell.Contains("interface PayloadMarker {") &&
            pg2Shell.Contains("marker.assembly === assembly && marker.entries > 0");
    }
}
bool pg2MarkerOk = pg2MarkerTargetsOk && pg2MarkerShellOk;
Console.WriteLine($"[verify] pg2 payload marker packs=22,23,24 targets={pg2MarkerTargetsOk} shell={pg2MarkerShellOk} source='{pg2MarkerPath ?? "<missing>"}' assert={pg2MarkerOk}");
if (!pg2MarkerOk)
{
    throw new InvalidOperationException(
        $"the PG2 .dotnet-payload.json marker contract drifted: targets={pg2MarkerTargetsOk} " +
        $"shell={pg2MarkerShellOk} source={pg2MarkerPath ?? "<missing>"}");
}

// PG2h: the exec-memory policy: the definition, both launch-path calls before their
// OhosHostOpenHostfxr (the start_app path re-applies it when a pending context is adopted), the
// DOTNET_EnableWriteXorExecute environment pin and the xwe=0|1 source=default|file log in both
// forms.
bool pg2PolicyDefOk = cSource?.Contains("static void OhosHostApplyExecMemoryPolicy(const char* caller, const char* app_dir, const char* context_json) {") == true;
int pg2PolicyRunAt = pg2RunAt < 0 ? -1 : cSource!.IndexOf("OhosHostApplyExecMemoryPolicy(\"run_app\", effective_app_dir, NULL);", pg2RunAt, StringComparison.Ordinal);
int pg2PolicyStartAt = pg2StartAt < 0 ? -1 : cSource!.IndexOf("OhosHostApplyExecMemoryPolicy(\"start_app\", effective_app_dir, context_json);", pg2StartAt, StringComparison.Ordinal);
bool pg2PolicyPathsOk = pg2PolicyRunAt > pg2RunBridgeAt && pg2PolicyRunAt < pg2RunHostfxrAt &&
    pg2PolicyStartAt > pg2StartBridgeAt && pg2PolicyStartAt < pg2StartHostfxrAt;
bool pg2PolicyEnvOk = cSource?.Contains("setenv(\"DOTNET_EnableWriteXorExecute\", enabled ? \"1\" : \"0\", 1);") == true;
bool pg2PolicyLogOk = cSource?.Contains("\"[openharmony-host] %{public}s: xwe=%{public}d source=%{public}s\"") == true &&
    cSource!.Contains("fprintf(stderr, \"[openharmony-host] %s: xwe=%d source=%s\\n\", name, enabled, source);");
bool pg2PolicyOk = pg2PolicyDefOk && pg2PolicyPathsOk && pg2PolicyEnvOk && pg2PolicyLogOk;
Console.WriteLine($"[verify] pg2 host exec memory policy defined={pg2PolicyDefOk} bothPaths={pg2PolicyPathsOk} env={pg2PolicyEnvOk} xweLog={pg2PolicyLogOk} source='{cSourcePath ?? "<missing>"}' assert={pg2PolicyOk}");
if (!pg2PolicyOk)
{
    throw new InvalidOperationException(
        $"the PG2 exec-memory policy drifted: defined={pg2PolicyDefOk} paths={pg2PolicyPathsOk} " +
        $"env={pg2PolicyEnvOk} log={pg2PolicyLogOk} source={cSourcePath ?? "<missing>"}");
}

// PG2i: the one-shot exec-memory probe: the once guard, the `OHOS_DOTNET probe: 1=... 4=...`
// mapping line and its dotnet-status.txt append.
bool pg2ProbeDefOk = cSource?.Contains("static void OhosHostProbeExecMemoryOnce(const char* status_dir) {") == true;
bool pg2ProbeOnceOk = cSource?.Contains("static int g_exec_probe_done = 0;") == true &&
    cSource!.Contains("if (g_exec_probe_done) {\n        return;\n    }");
bool pg2ProbeTokenOk = cSource?.Contains("snprintf(line, sizeof(line), \"OHOS_DOTNET probe: 1=%s 2=%s 3=%s 4=%s\", r1, r2, r3, r4);") == true;
bool pg2ProbeStatusOk = cSource?.Contains("OhosHostAppendStatusLine(status_dir, line);") == true;
bool pg2ProbeOk = pg2ProbeDefOk && pg2ProbeOnceOk && pg2ProbeTokenOk && pg2ProbeStatusOk;
Console.WriteLine($"[verify] pg2 host exec memory probe defined={pg2ProbeDefOk} oneShot={pg2ProbeOnceOk} token={pg2ProbeTokenOk} status={pg2ProbeStatusOk} source='{cSourcePath ?? "<missing>"}' assert={pg2ProbeOk}");
if (!pg2ProbeOk)
{
    throw new InvalidOperationException(
        $"the PG2 exec-memory probe drifted: defined={pg2ProbeDefOk} once={pg2ProbeOnceOk} " +
        $"token={pg2ProbeTokenOk} status={pg2ProbeStatusOk} source={cSourcePath ?? "<missing>"}");
}

// ---- Audit batch-3 pins: the FIX-MAUI security residuals (MB-1/MB-2/MB-3/H-C2) ----------------
// The slice fixes at maui-ohos c730226f closed the batch-3 findings - the unbounded web approval
// table, application exceptions escaping a native -> managed callback, unvetted app-package
// names and the approval/load URL channels - but shipped without behavioural pins here. Each fix
// gets the off-device contract the scratch harness exercised: the real approval dictionary and
// the private native entries are driven directly, and the hosting bridge's own native callbacks
// (this repository, MB-2) get the same treatment, so a removed try/catch fails this run. The
// probes share one throwaway bridge context (AppDir for the package probes, FilesDir for the
// swallowed-exception status lines) that is restored afterwards.

MethodInfo Audit3NativeEntry(Type type, string name)
    => type.GetMethod(name, BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException($"{type.Name}.{name} was not found; the audit batch-3 pins drive the native entry directly");

// MB-1: 200 approved main-frame navigations leave the table bounded at the 64-entry cap with the
// newest decision kept; an expired marker is pruned by a page event; a full table evicts the
// entry closest to expiry; the matching "started" event still consumes its entry exactly once.
FieldInfo n30ApprovalsField = typeof(OpenHarmonyWebViewHandler)
    .GetField("s_approvedNavigations", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyWebViewHandler.s_approvedNavigations was not found; the MB-1 cap pin needs the approval table");
var n30Approvals = (Dictionary<string, long>)n30ApprovalsField.GetValue(null)!;
string n30NewestUrl = string.Empty;
for (int n30Index = 0; n30Index < 200; n30Index++)
{
    n30NewestUrl = $"https://example.invalid/nav/{n30Index}/{new string('A', 64)}";
    OpenHarmonyWebViewHandler.HandleJsMessage($"__OHNAV|{n30NewestUrl}|id-{n30Index}");
}
int n30CapCount = n30Approvals.Count;
bool n30CapOk = n30CapCount == 64;
bool n30NewestOk = n30Approvals.ContainsKey(n30NewestUrl);
string n30StaleUrl = "https://stale.invalid/never-started";
n30Approvals[n30StaleUrl] = Environment.TickCount64 - 1;
OpenHarmonyWebViewHandler.OnPageEvent("finished", "https://example.invalid/done");
bool n30TtlOk = !n30Approvals.ContainsKey(n30StaleUrl);
string n30ClosestToExpiry = n30Approvals.OrderBy(entry => entry.Value).First().Key;
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.invalid/late|id-late");
bool n30EvictOk = n30Approvals.Count <= 64 && !n30Approvals.ContainsKey(n30ClosestToExpiry) &&
    n30Approvals.ContainsKey("https://example.invalid/late");
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.invalid/one-shot|id-one-shot");
bool n30OneShotApproved = n30Approvals.ContainsKey("https://example.invalid/one-shot");
OpenHarmonyWebViewHandler.OnPageEvent("started", "https://example.invalid/one-shot");
bool n30OneShotOk = n30OneShotApproved && !n30Approvals.ContainsKey("https://example.invalid/one-shot");
bool n30Mb1Ok = n30CapOk && n30NewestOk && n30TtlOk && n30EvictOk && n30OneShotOk;
Console.WriteLine($"[verify] audit3 mb1 approvals cap={n30CapOk}(count={n30CapCount}) newest={n30NewestOk} ttlPruned={n30TtlOk} evictedOldest={n30EvictOk} oneShot={n30OneShotOk} assert={n30Mb1Ok}");
if (!n30Mb1Ok)
{
    throw new InvalidOperationException(
        $"the bounded web-approval table (MB-1) drifted: cap={n30CapOk} newest={n30NewestOk} " +
        $"ttl={n30TtlOk} evict={n30EvictOk} oneShot={n30OneShotOk}");
}

// A throwaway bridge context for the package probes and the swallowed-exception status lines.
string n30AuditRoot = Path.Combine(Path.GetTempPath(), "verify-audit3");
string n30StatusDir = Path.Combine(n30AuditRoot, "status");
string n30AppDir = Path.Combine(n30AuditRoot, "app");
Directory.CreateDirectory(n30StatusDir);
Directory.CreateDirectory(n30AppDir);
Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext? n30ContextBefore =
    (Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext?)bridgeContextField.GetValue(null);
FieldInfo n30SurfaceField = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
    .GetField("s_surface", BindingFlags.NonPublic | BindingFlags.Static)
    ?? throw new InvalidOperationException("OpenHarmonyBridge.s_surface was not found; the host surface pin saves/restores it");
Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo? n30SurfaceBefore =
    (Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo?)n30SurfaceField.GetValue(null);
SetBridgeContext(new Microsoft.OpenHarmony.Hosting.OpenHarmonyAppContext { FilesDir = n30StatusDir, AppDir = n30AppDir });
string n30StatusPath = Path.Combine(n30StatusDir, "dotnet-status.txt");
File.Delete(n30StatusPath);

// MB-3: app-package names are canonicalized ('/' separators, no "." or ".." segments) and every
// traversal, rooted, drive-letter, UNC and control-character spelling is refused, while legal
// relative names keep the missing-file contract (they reach the rawfile fallback, not a throw).
var n30FileSystem = new OpenHarmonyFileSystem();
string[] n30BadNames =
{
    "../secret", "..", "/etc/passwd", "//server/share/x", "C:\\Windows\\win.ini", "C:file",
    "a\\..\\b", "..\\x", "a//b", "a/", "sub/../../x", ".", "a\0b",
};
int n30NsRejected = 0;
foreach (string n30Name in n30BadNames)
{
    try
    {
        _ = n30FileSystem.OpenAppPackageFileAsync(n30Name);
    }
    catch (ArgumentException)
    {
        n30NsRejected++;
    }
}
string[] n30GoodNames = { "index.html", "wwwroot/index.html", "a\\b\\c.txt", "./x/y.html", "a/./b.txt" };
int n30AllowedMisses = 0;
bool n30SeparatorsNormalized = false;
foreach (string n30Name in n30GoodNames)
{
    try
    {
        _ = n30FileSystem.OpenAppPackageFileAsync(n30Name).GetAwaiter().GetResult();
    }
    catch (FileNotFoundException n30Missing)
    {
        n30AllowedMisses++;
        if (n30Name == "a\\b\\c.txt")
        {
            n30SeparatorsNormalized = n30Missing.Message.Contains("'a/b/c.txt'");
        }
    }
}
bool n30ExistsRejected = false;
try
{
    _ = n30FileSystem.AppPackageFileExistsAsync("../x").GetAwaiter().GetResult();
}
catch (ArgumentException)
{
    n30ExistsRejected = true;
}
bool n30Mb3Ok = n30NsRejected == n30BadNames.Length && n30AllowedMisses == n30GoodNames.Length &&
    n30SeparatorsNormalized && n30ExistsRejected;
Console.WriteLine($"[verify] audit3 mb3 apppackage rejected={n30NsRejected}/{n30BadNames.Length} allowed={n30AllowedMisses}/{n30GoodNames.Length} normalized={n30SeparatorsNormalized} existsRejected={n30ExistsRejected} assert={n30Mb3Ok}");
if (!n30Mb3Ok)
{
    throw new InvalidOperationException(
        $"the app-package name validation (MB-3) drifted: rejected={n30NsRejected} allowed={n30AllowedMisses} " +
        $"normalized={n30SeparatorsNormalized} existsRejected={n30ExistsRejected}");
}

// H-C2 (approval channel): only an absolute http(s) target with a host may be approved back to
// the shell; the spellings a URI parser turns into a file/foreign target stay blocked.
var n30ApprovalsSent = new List<(string Id, string Url)>();
void Audit3OnApproval(string id, string url) => n30ApprovalsSent.Add((id, url));
OpenHarmonyWebViewHandler.NavigationApprovalSent += Audit3OnApproval;
string[] n30BlockedTargets =
{
    "//evil.invalid/x", "///evil.invalid", "/\\evil.invalid", "//evil.invalid:8443/x",
    "file://evil.invalid/x", "mailto:a@b.c", "javascript:alert(1)", "data:text/html,x",
};
int n30BlockedKept = 0;
foreach (string n30Target in n30BlockedTargets)
{
    int n30SentBefore = n30ApprovalsSent.Count;
    OpenHarmonyWebViewHandler.HandleJsMessage($"__OHNAV|{n30Target}|id-bad");
    n30BlockedKept += n30ApprovalsSent.Count == n30SentBefore ? 1 : 0;
}
OpenHarmonyWebViewHandler.HandleJsMessage("__OHNAV|https://example.invalid/ok|id-ok");
bool n30ApprovedOk = n30ApprovalsSent.Count == 1 && n30ApprovalsSent[0] == ("id-ok", "https://example.invalid/ok");
OpenHarmonyWebViewHandler.NavigationApprovalSent -= Audit3OnApproval;
bool n30ApprovalOk = n30BlockedKept == n30BlockedTargets.Length && n30ApprovedOk;
Console.WriteLine($"[verify] audit3 hc2 approvals blocked={n30BlockedKept}/{n30BlockedTargets.Length} accepted={n30ApprovedOk} assert={n30ApprovalOk}");
if (!n30ApprovalOk)
{
    throw new InvalidOperationException(
        $"the approval channel (H-C2) drifted: blocked={n30BlockedKept}/{n30BlockedTargets.Length} accepted={n30ApprovedOk}");
}

// H-C2 (app-requested load path): app-internal references and the shell's own schemes stay
// loadable; network-path/UNC spellings, scheme-like spellings and unknown schemes are refused.
(string Url, bool Allowed)[] n30LoadCases =
{
    ("//evil.invalid/x", false),
    ("/\\evil.invalid", false),
    ("\\\\evil.invalid\\x", false),
    (" //evil.invalid/x", false),
    ("\t//evil.invalid/x", false),
    ("https:foo", false),
    ("https:/evil.invalid", false),
    ("mailto:a@b.c", false),
    ("javascript:alert(1)", false),
    ("/index.html", true),
    ("#frag", true),
    ("?q=1", true),
    ("page2.html", true),
    ("sub/dir/page2.html", true),
    ("https://example.invalid/x", true),
    ("http://example.invalid:8080/x", true),
    ("file:///data/storage/el2/base/files/index.html", true),
    ("file://evil.invalid/x", false),
    ("data:text/html,<p>hi</p>", true),
    ("about:blank", true),
    ("blob:https://0.0.0.0/1234", true),
};
int n30LoadRejected = 0;
int n30LoadAllowed = 0;
int n30LoadUnexpected = 0;
foreach ((string n30Url, bool n30CaseAllowed) in n30LoadCases)
{
    bool n30Actual = OpenHarmonyWebViewHandler.IsLoadableSourceUrl(n30Url);
    if (n30Actual == n30CaseAllowed)
    {
        n30LoadRejected += n30CaseAllowed ? 0 : 1;
        n30LoadAllowed += n30CaseAllowed ? 1 : 0;
    }
    else
    {
        n30LoadUnexpected++;
    }
}
bool n30LoadOk = n30LoadUnexpected == 0;
Console.WriteLine($"[verify] audit3 hc2 load cases={n30LoadCases.Length} rejected={n30LoadRejected} allowed={n30LoadAllowed} unexpected={n30LoadUnexpected} assert={n30LoadOk}");
if (!n30LoadOk)
{
    throw new InvalidOperationException($"the app-requested load table (H-C2) drifted on {n30LoadUnexpected} case(s)");
}

// MB-2 (slice): a throwing application handler must not escape the reverse P/Invoke boundary.
// Each probe attaches a throwing handler to the app-facing event and drives the private native
// entry the shell's notification lands on; the matching source guard is pinned too, because the
// menu/theme/hybrid entries cannot always be made to throw from a synthetic call.
var n30SliceEscapes = new List<string>();
void Audit3ExpectGuarded(string name, Action invoke)
{
    try
    {
        invoke();
    }
    catch (Exception ex)
    {
        n30SliceEscapes.Add(name + ":" + ex.GetType().Name);
        Console.WriteLine($"[verify] audit3 mb2 escaped {name}: {ex.GetType().Name}: {ex.Message}");
    }
}

Action<string> n30JsThrower = _ => throw new InvalidOperationException("app js handler failed\nsecond line");
OpenHarmonyWebViewHandler.JsMessage += n30JsThrower;
Audit3ExpectGuarded("webview", () =>
{
    IntPtr n30Payload = Marshal.StringToCoTaskMemUTF8("{\"pad\":\"x\"}");
    try
    {
        Audit3NativeEntry(typeof(OpenHarmonyWebViewHandler), "OnJsMessageNative").Invoke(null, new object?[] { n30Payload });
    }
    finally
    {
        Marshal.FreeCoTaskMem(n30Payload);
    }
});
OpenHarmonyWebViewHandler.JsMessage -= n30JsThrower;

EventHandler<OpenHarmonyGattValueChangedEventArgs> n30GattThrower =
    (_, _) => throw new InvalidOperationException("app gatt handler failed");
OpenHarmonyBluetoothGatt.ValueChanged += n30GattThrower;
Audit3ExpectGuarded("gatt", () =>
{
    IntPtr n30Payload = Marshal.StringToCoTaskMemUTF8(
        "value\tAA:BB:CC\t0000fff0-0000-1000-8000-00805f9b34fb\t0000fff1-0000-1000-8000-00805f9b34fb\tAAECAwQ=");
    try
    {
        Audit3NativeEntry(typeof(OpenHarmonyBluetoothGatt), "OnEventNative").Invoke(null, new object?[] { n30Payload });
    }
    finally
    {
        Marshal.FreeCoTaskMem(n30Payload);
    }
});
OpenHarmonyBluetoothGatt.ValueChanged -= n30GattThrower;

Action n30ClipboardThrower = () => throw new InvalidOperationException("app clipboard handler failed");
OpenHarmonyClipboardBridge.Changed += n30ClipboardThrower;
Audit3ExpectGuarded("clipboard", () => Audit3NativeEntry(typeof(OpenHarmonyClipboardBridge), "OnNativeClipboardChanged").Invoke(null, null));
OpenHarmonyClipboardBridge.Changed -= n30ClipboardThrower;

EventHandler<Microsoft.Maui.Devices.Sensors.AccelerometerChangedEventArgs> n30SensorThrower =
    (_, _) => throw new InvalidOperationException("app sensor handler failed");
OpenHarmonyAccelerometer.Instance.ReadingChanged += n30SensorThrower;
Audit3ExpectGuarded("sensors", () =>
{
    foreach (int n30SensorType in new[] { 1, 2, 6, 8, 259 })
    {
        Audit3NativeEntry(typeof(OpenHarmonySensors), "OnReading")
            .Invoke(null, new object?[] { n30SensorType, 0f, 0f, 9.8f, 0f, 0L });
    }
});
OpenHarmonyAccelerometer.Instance.ReadingChanged -= n30SensorThrower;

Audit3ExpectGuarded("menus", () => Audit3NativeEntry(typeof(OpenHarmonyMenus), "OnMenuActionNative").Invoke(null, new object?[] { 7 }));
Audit3ExpectGuarded("theme", () => Audit3NativeEntry(typeof(OpenHarmonyTheme), "OnNativeTheme").Invoke(null, new object?[] { 1 }));
Audit3ExpectGuarded("hybrid", () =>
{
    IntPtr n30Method = Marshal.StringToCoTaskMemUTF8("noop");
    IntPtr n30Arguments = Marshal.StringToCoTaskMemUTF8("[]");
    try
    {
        Audit3NativeEntry(typeof(OpenHarmonyHybridWebViewHandler), "OnHybridInvokeNative")
            .Invoke(null, new object?[] { 1, n30Method, n30Arguments });
    }
    finally
    {
        Marshal.FreeCoTaskMem(n30Method);
        Marshal.FreeCoTaskMem(n30Arguments);
    }
});

(string File, string Guard)[] n30GuardSources =
{
    ("OpenHarmonyWebViewHandler.cs", "NativeCallbackFailed(\"web js message\", ex)"),
    ("OpenHarmonyBluetoothGatt.cs", "NativeCallbackFailed(\"bluetooth gatt event\", ex)"),
    ("OpenHarmonyEssentialsBridges.cs", "NativeCallbackFailed(\"clipboard changed\", ex)"),
    ("OpenHarmonySensors.cs", "NativeCallbackFailed(\"sensor reading\", ex)"),
    ("OpenHarmonyMenus.cs", "NativeCallbackFailed(\"menu action\", ex)"),
    ("OpenHarmonyTheme.cs", "NativeCallbackFailed(\"theme change\", ex)"),
    ("OpenHarmonyHybridWebViewHandler.cs", "NativeCallbackFailed(\"hybrid invoke\", ex)"),
};
int n30GuardSourceHits = 0;
string n30GuardSourceMissing = string.Empty;
foreach ((string n30GuardFile, string n30GuardText) in n30GuardSources)
{
    string? n30GuardPath = FindHostSource(n30GuardFile);
    bool n30GuardFound = n30GuardPath is not null &&
        File.ReadAllText(n30GuardPath).Contains(n30GuardText, StringComparison.Ordinal);
    n30GuardSourceHits += n30GuardFound ? 1 : 0;
    if (!n30GuardFound)
    {
        n30GuardSourceMissing += (n30GuardSourceMissing.Length == 0 ? string.Empty : ",") + n30GuardFile;
    }
}
bool n30Mb2GuardsOk = n30SliceEscapes.Count == 0 && n30GuardSourceHits == n30GuardSources.Length;
Console.WriteLine($"[verify] audit3 mb2 guards guarded=7 escaped={n30SliceEscapes.Count} sources={n30GuardSourceHits}/{n30GuardSources.Length} missing='{n30GuardSourceMissing}' assert={n30Mb2GuardsOk}");
if (!n30Mb2GuardsOk)
{
    throw new InvalidOperationException(
        $"a slice native-callback guard (MB-2) drifted: escaped={string.Join(",", n30SliceEscapes)} " +
        $"sources={n30GuardSourceHits}/{n30GuardSources.Length} missing='{n30GuardSourceMissing}'");
}

// MB-2 (hosting bridge): the repository's own reverse P/Invoke entries. The private handler
// delegate is swapped for a throwing one, the native entry the shell calls is invoked, and the
// app-facing subscribers are restored afterwards, so the probe leaves no state behind. The
// source contract pins the inline guards on all ten entries.
int n30HostEntries = 0;
var n30HostEscapes = new List<string>();
void Audit3ProbeHostCallback(string boundary, string fieldName, string methodName, Delegate thrower, object?[] arguments)
{
    FieldInfo n30Field = typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge)
        .GetField(fieldName, BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException($"OpenHarmonyBridge.{fieldName} was not found; the host callback pin needs the handler seam");
    object? n30Before = n30Field.GetValue(null);
    n30Field.SetValue(null, thrower);
    try
    {
        n30HostEntries++;
        Audit3NativeEntry(typeof(Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge), methodName).Invoke(null, arguments);
    }
    catch (Exception ex)
    {
        n30HostEscapes.Add(boundary + ":" + ex.GetType().Name);
        Console.WriteLine($"[verify] audit3 host escaped {boundary}: {ex.GetType().Name}: {ex.Message}");
    }
    finally
    {
        n30Field.SetValue(null, n30Before);
    }
}

Action<Microsoft.OpenHarmony.Hosting.OpenHarmonyTouchEventArgs> n30TouchThrower =
    _ => throw new InvalidOperationException("app touch handler failed");
Audit3ProbeHostCallback("touch", "s_touchHandlers", "OnTouchNative", n30TouchThrower, new object?[] { 0, 0f, 0f, 1, 1 });

Action<Microsoft.OpenHarmony.Hosting.OpenHarmonyFrameEventArgs> n30FrameThrower =
    _ => throw new InvalidOperationException("app frame handler failed");
Audit3ProbeHostCallback("frame", "s_frameHandlers", "OnFrameNative", n30FrameThrower, new object?[] { 0L, 0L });

Action<string> n30TextInputThrower = _ => throw new InvalidOperationException("app text input handler failed");
Audit3ProbeHostCallback("text input", "s_textInputHandlers", "OnTextInputNative", n30TextInputThrower, new object?[] { IntPtr.Zero });

Action n30TextSubmittedThrower = () => throw new InvalidOperationException("app text submitted handler failed");
Audit3ProbeHostCallback("text submitted", "s_textSubmittedHandlers", "OnTextSubmittedNative", n30TextSubmittedThrower, Array.Empty<object?>());

Action<Microsoft.OpenHarmony.Hosting.OpenHarmonyLifecycleEvent> n30LifecycleThrower =
    _ => throw new InvalidOperationException("app lifecycle handler failed");
Audit3ProbeHostCallback("lifecycle", "s_lifecycleHandlers", "OnLifecycleNative", n30LifecycleThrower, new object?[] { 2 });

Action<Microsoft.OpenHarmony.Hosting.OpenHarmonySurfaceInfo> n30SurfaceThrower =
    _ => throw new InvalidOperationException("app surface handler failed");
Audit3ProbeHostCallback("surface", "s_surfaceHandlers", "OnSurfaceNative", n30SurfaceThrower, new object?[] { IntPtr.Zero, 1080, 1920, 0 });

Action<int, double, float, float> n30PinchThrower =
    (_, _, _, _) => throw new InvalidOperationException("app pinch handler failed");
Audit3ProbeHostCallback("pinch", "Pinch", "OnPinch", n30PinchThrower, new object?[] { 1, 1.0, 0f, 0f });

Action<string, string> n30WebEventThrower =
    (_, _) => throw new InvalidOperationException("app web event handler failed");
Audit3ProbeHostCallback("web event", "WebEvent", "OnWebEventNative", n30WebEventThrower, new object?[] { IntPtr.Zero, IntPtr.Zero });

Action<int, int, string, string> n30PickerThrower =
    (_, _, _, _) => throw new InvalidOperationException("app picker result handler failed");
Audit3ProbeHostCallback("picker result", "PickerResult", "OnPickerResultNative", n30PickerThrower, new object?[] { 99999, 1, IntPtr.Zero, IntPtr.Zero });

Action<int, int, string> n30KeystoreThrower =
    (_, _, _) => throw new InvalidOperationException("app keystore result handler failed");
Audit3ProbeHostCallback("keystore result", "KeystoreResult", "OnKeystoreResultNative", n30KeystoreThrower, new object?[] { 99999, 1, IntPtr.Zero });

// MB-2 (status channel): the swallowed failures reach dotnet-status.txt as one flattened line
// per boundary, and the hosting bridge reports its own ten boundaries the same way.
string n30StatusLog = File.Exists(n30StatusPath) ? File.ReadAllText(n30StatusPath) : string.Empty;
bool n30FlattenedOk =
    n30StatusLog.Contains("web js message callback failed: InvalidOperationException: app js handler failed second line") &&
    n30StatusLog.Contains("bluetooth gatt event callback failed: InvalidOperationException: app gatt handler failed") &&
    n30StatusLog.Contains("clipboard changed callback failed: InvalidOperationException: app clipboard handler failed") &&
    n30StatusLog.Contains("sensor reading callback failed: InvalidOperationException: app sensor handler failed");
Console.WriteLine($"[verify] audit3 mb2 status flattened={n30FlattenedOk} bytes={n30StatusLog.Length} assert={n30FlattenedOk}");
if (!n30FlattenedOk)
{
    throw new InvalidOperationException("a swallowed native-callback failure (MB-2) did not reach dotnet-status.txt as one flattened line");
}

string[] n30HostStatusLines =
{
    "touch callback failed: InvalidOperationException: app touch handler failed",
    "frame callback failed: InvalidOperationException: app frame handler failed",
    "text input callback failed: InvalidOperationException: app text input handler failed",
    "text submitted callback failed: InvalidOperationException: app text submitted handler failed",
    "lifecycle callback failed: InvalidOperationException: app lifecycle handler failed",
    "surface callback failed: InvalidOperationException: app surface handler failed",
    "pinch callback failed: InvalidOperationException: app pinch handler failed",
    "web event callback failed: InvalidOperationException: app web event handler failed",
    "picker result callback failed: InvalidOperationException: app picker result handler failed",
    "keystore result callback failed: InvalidOperationException: app keystore result handler failed",
};
int n30HostLogged = n30HostStatusLines.Count(line => n30StatusLog.Contains(line, StringComparison.Ordinal));
string? n30HostingPath = FindHostSource("src/Microsoft.OpenHarmony.Hosting/OpenHarmonyApp.cs");
string n30HostingSource = n30HostingPath is null ? string.Empty : File.ReadAllText(n30HostingPath);
int n30HostGuardsPinned = 0;
foreach (string n30Boundary in new[]
{
    "touch", "frame", "text input", "text submitted", "lifecycle", "surface", "pinch",
    "web event", "picker result", "keystore result",
})
{
    n30HostGuardsPinned += n30HostingSource.Contains($"ReportCallbackFailure(\"{n30Boundary}\", ex)") ? 1 : 0;
}
bool n30HostOk = n30HostEntries == 10 && n30HostEscapes.Count == 0 &&
    n30HostLogged == n30HostStatusLines.Length && n30HostGuardsPinned == 10;
Console.WriteLine($"[verify] audit3 host callbacks entries={n30HostEntries} escaped={n30HostEscapes.Count} status={n30HostLogged}/{n30HostStatusLines.Length} guards={n30HostGuardsPinned}/10 source='{n30HostingPath ?? "<missing>"}' assert={n30HostOk}");
if (!n30HostOk)
{
    throw new InvalidOperationException(
        $"a hosting native-callback guard (MB-2) drifted: entries={n30HostEntries} escaped={string.Join(",", n30HostEscapes)} " +
        $"status={n30HostLogged}/{n30HostStatusLines.Length} guards={n30HostGuardsPinned}/10");
}

SetBridgeContext(n30ContextBefore);
n30SurfaceField.SetValue(null, n30SurfaceBefore);
try
{
    Directory.Delete(n30AuditRoot, true);
}
catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
{
    // The audit scratch directory is diagnostic only; leaving it behind must not fail the suite.
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
// canvas calls - the same shape the deep-tree fuzz section uses.
//   * alloc/frame <= 13,824 B - the allocation gate, re-based after the managed perf batch
//     (maui-ohos 0e9d90cd: text metrics, carousel slides and rawfile answer caches): 3x the
//     4,504 B/frame baseline measured on this host, where the delta is deterministic
//     (900,800 B per 200-frame run on every repeat), so unlike the wall-clock budgets this gate
//     needs no noise slack. 3x = 13,512 B, rounded up to the next 512-byte boundary (13.5 KiB =
//     3.07x) so the ceiling is a tidy unit with a hair of margin and stays at the lower end of
//     the review's documented 3-4x band. The pre-batch baseline was 72,864 B/frame here
//     (72,056-72,080 B/frame on CI, the same Debug codegen within 1.1%) and the pre-FIX-P2 storm
//     measured 241,688 B/frame = 3.3x of it, which the old 218,592 B ceiling caught; if a
//     legitimate baseline growth lands near the new ceiling, raise the constant deliberately
//     rather than loosening the check silently.
//   * jitter (p95/avg) <= 2.0 - the frame-to-frame stability gate. The raw max/avg (bounded by
//     the loose 100x outlier guard above) is not a stable signal on a loaded shared host: a
//     single preempted frame measured 3.4x here while the frame path was healthy, and the
//     pre-FIX-P2 baseline run logged 8.1x. p95/avg is robust to one or two preempted frames and
//     still catches a sustained regression (every frame, or at least one frame in twenty,
//     getting slower): it measured 1.08x on CI and 1.3-1.7x on the dev host (1.30-1.31x after
//     the managed perf batch), so 2.0x keeps a documented margin while the old 100x guard stays
//     as the single-frame hang check.
const int perfWarmupFrames = 8;
const int perfFrames = 200;
const double perfAverageCeilingMs = 20.0;
const double perfMaxCeilingMs = 250.0;
const double perfMaxAverageRatio = 100.0;
const double perfJitterCeiling = 2.0;
const double perfAllocPerFrameCeiling = 13_824.0;
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
double perfJitter = perfP95 / Math.Max(perfAverage, 1e-9);
double perfAllocPerFrame = perfAllocDelta / (double)perfFrames;
bool perfWithinBudget = perfAverage <= perfAverageCeilingMs
    && perfMax <= perfMaxCeilingMs
    && perfMaxAverage <= perfMaxAverageRatio
    && perfJitter <= perfJitterCeiling
    && perfAllocPerFrame <= perfAllocPerFrameCeiling;
Console.WriteLine($"[verify] perf warmup={perfWarmupFrames} frames={perfFrames} nodes={perfNodes} avg={perfAverage:0.###}ms p50={perfP50:0.###}ms p95={perfP95:0.###}ms max={perfMax:0.###}ms max/avg={perfMaxAverage:0.##} jitter={perfJitter:0.##} allocDelta={perfAllocDelta}B alloc/frame={perfAllocPerFrame:0.#}B elapsed={(int)perfWatch.ElapsedMilliseconds}ms budget=avg<={perfAverageCeilingMs:0.###}ms,max<={perfMaxCeilingMs:0.###}ms,max/avg<={perfMaxAverageRatio:0.###},jitter<={perfJitterCeiling:0.##},alloc/frame<={perfAllocPerFrameCeiling:0.#}B warmupOk={perfWarm} within={perfWithinBudget}");
if (!perfWarm || !perfWithinBudget)
{
    throw new InvalidOperationException(
        $"the frame-path performance budget failed: avg={perfAverage:0.###}ms (limit {perfAverageCeilingMs}ms) " +
        $"max={perfMax:0.###}ms (limit {perfMaxCeilingMs}ms) max/avg={perfMaxAverage:0.##} (limit {perfMaxAverageRatio}) " +
        $"jitter={perfJitter:0.##} (limit {perfJitterCeiling}, p95/avg) " +
        $"alloc/frame={perfAllocPerFrame:0.#}B (limit {perfAllocPerFrameCeiling:0.#}B) " +
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

// The suite's own check-count contract: report what was actually emitted and fail when it is
// below the declared floor. The CI job and scripts/preflight.sh read this line instead of
// repeating a threshold constant, so the count has a single source of truth (this file) and
// cannot drift between the two callers. `grep -c '[verify]'` must agree with `checks=`.
int verifyChecks = verifyStdout.VerifyLineCount;
bool verifyCheckContract = verifyChecks >= verifyCheckFloor;
Console.WriteLine($"[suite] checks={verifyChecks} total={verifyCheckTotal} floor={verifyCheckFloor} assert={verifyCheckContract}");
if (!verifyCheckContract)
{
    throw new InvalidOperationException(
        $"the interaction suite printed {verifyChecks} [verify] lines, below the {verifyCheckFloor}-line floor (declared total {verifyCheckTotal})");
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

/// <summary>
/// Passthrough stdout writer that counts the complete lines carrying the "[verify]" check
/// marker, so the suite can state its own contract line count in the [suite] summary and fail
/// when the run is below the declared floor.
/// </summary>
sealed class VerifyLineCountingWriter : TextWriter
{
    private readonly TextWriter _inner;
    private readonly System.Text.StringBuilder _line = new();

    public VerifyLineCountingWriter(TextWriter inner) => _inner = inner;

    public int VerifyLineCount { get; private set; }

    public override System.Text.Encoding Encoding => _inner.Encoding;

    public override void Flush() => _inner.Flush();

    public override void Write(char value)
    {
        Track(value);
        _inner.Write(value);
    }

    public override void Write(string? value)
    {
        if (value is null)
        {
            return;
        }

        foreach (char c in value)
        {
            Track(c);
        }

        _inner.Write(value);
    }

    private void Track(char c)
    {
        if (c == '\n')
        {
            if (_line.ToString().Contains("[verify]", StringComparison.Ordinal))
            {
                VerifyLineCount++;
            }

            _line.Clear();
        }
        else if (c != '\r')
        {
            _line.Append(c);
        }
    }
}
