// Map Kit overlay module (R2-3 option (a), 2026-09-26).
//
// This file is the only place that names the MapComponent ArkUI component, whose declaration
// exists in the HarmonyOS SDK (hms/ets) but not in the OpenHarmony SDK. The default shell build
// therefore never copies or compiles it; scripts/build-arkts-shell.sh picks it up only in the
// ARKTS_SDK_FLAVOR=harmony branch, next to pages/Index.ets. Index.ets pulls the compiled module
// in through a dynamic import whose specifier stays in a variable ('./map/MapOverlay') and casts
// the resolved value to its local HmsMapOverlayModule/HmsMapOverlayProxy interfaces, so:
//   * the default OpenHarmony SDK build stays free of the component declaration and answers
//     capability bit 1 = 0 (the overlay module does not resolve and the Map sink answers -1);
//   * the harmony build compiles this file against the real kit types and the overlay lights up
//     on a device whose runtime provides @kit.MapKit (plus the AGC map service AppKey).
//
// The proxy owns the map view lifecycle: Index.ets creates one when the managed side asks for the
// overlay (Map sink op 1), renders proxy.nodeController through NodeContainer, and calls
// setRegion/addMarker/dispose for the remaining ops. The module never talks to the host directly:
// its MapOverlayEvents callbacks are the shell's, which forwards them through the Map sink.
import { MapComponent, map, mapCommon } from '@kit.MapKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Same domain/tag pair as pages/Index.ets, so the overlay's diagnostics land next to the shell's.
const DOMAIN = 0x0002;
const TAG = 'OHOS_MAUI';

// The same shapes Index.ets declares locally (the module boundary is a structural cast, so this
// file may evolve independently as long as the members used by the shell stay in place).
export interface MapOverlayRegion {
  latitude: number;
  longitude: number;
  zoom: number;
}

export interface MapOverlayMarker {
  id: string;
  latitude: number;
  longitude: number;
  title: string;
}

export interface MapOverlayEvents {
  onReady: () => void;
  onMarkerClick: (id: string) => void;
  onCameraIdle: (latitude: number, longitude: number, zoom: number) => void;
}

// Builder parameter object. An explicit interface (not an inline literal) is required by the
// ArkTS linter for @Builder parameters, and keeping it opaque lets the builder body stay free of
// proxy state.
interface MapOverlayViewParams {
  options: mapCommon.MapOptions;
  callback: AsyncCallback<map.MapComponentController>;
}

// The managed surface sits above the XComponent/ContentSlot stack; the map view fills it. The
// camera position is required by MapOptions, so the proxy always supplies one (the managed create
// op carries the initial region; the fallback is the documented demo default).
@Builder
function mapOverlayView(params: MapOverlayViewParams): void {
  MapComponent({ mapOptions: params.options, mapCallback: params.callback })
    .width('100%')
    .height('100%')
}

// NodeController for the NodeContainer Index.ets renders. makeNode builds the MapComponent
// through a BuilderNode the first time the container mounts; the controller callback (see
// MapOverlayProxy.attach) reports readiness, and aboutToDisappear releases the BuilderNode once
// the container leaves the tree.
class MapOverlayNode extends NodeController {
  private proxy: MapOverlayProxy | undefined = undefined;
  private built: BuilderNode<[MapOverlayViewParams]> | undefined = undefined;
  private released: boolean = false;

  setProxy(proxy: MapOverlayProxy): void {
    this.proxy = proxy;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    const proxy = this.proxy;
    if (proxy === undefined || this.released || proxy.isDisposed()) {
      return null;
    }
    const node = new BuilderNode<[MapOverlayViewParams]>(uiContext);
    const params: MapOverlayViewParams = {
      options: proxy.buildOptions(),
      callback: (error: BusinessError, controller: map.MapComponentController): void => {
        if (error) {
          proxy.handleMapError(error);
        } else {
          proxy.attach(controller);
        }
      }
    };
    node.build(wrapBuilder(mapOverlayView), params);
    this.built = node;
    return node.getFrameNode();
  }

  // The shell drops the overlay by flipping its @State, so the NodeContainer unmounts and the
  // framework calls this: the BuilderNode (whose backend entity owns the MapComponent) is only
  // disposed here, never while it is still attached.
  aboutToDisappear(): void {
    this.released = true;
    this.proxy = undefined;
    const node = this.built;
    this.built = undefined;
    if (node !== undefined) {
      node.dispose();
    }
  }

  // Marks the controller released; the dispose itself happens in aboutToDisappear.
  release(): void {
    this.released = true;
    this.proxy = undefined;
  }
}

// Overlay control surface. One instance per created overlay; dispose() makes every later call a
// no-op so a late kit callback cannot reach the host after the shell destroyed the overlay.
export class MapOverlayProxy {
  private events: MapOverlayEvents;
  private region: MapOverlayRegion;
  private controller: map.MapComponentController | undefined = undefined;
  private node: MapOverlayNode;
  private disposed: boolean = false;
  // Kit marker id (marker.getId()) -> the managed marker id. The kit hands its own Marker back
  // on a click, so the id the app passed in is recovered through this table.
  private markerIds: Map<string, string> = new Map();

  constructor(uiContext: UIContext, events: MapOverlayEvents, region: MapOverlayRegion) {
    this.events = events;
    this.region = region;
    const node = new MapOverlayNode(uiContext);
    node.setProxy(this);
    this.node = node;
  }

  isDisposed(): boolean {
    return this.disposed;
  }

  // The NodeController hand-off Index.ets reads (NodeContainer(this.nodeController)).
  get nodeController(): NodeController {
    return this.node;
  }

  // MapOptions for the first MapComponent build: the current region is the initial camera.
  buildOptions(): mapCommon.MapOptions {
    return {
      position: {
        target: {
          latitude: this.region.latitude,
          longitude: this.region.longitude
        },
        zoom: this.region.zoom
      }
    };
  }

  // MapComponent initialization callback. Registers the kit callbacks, applies the region and
  // reports readiness once; a controller that arrives after dispose is ignored.
  attach(controller: map.MapComponentController): void {
    if (this.disposed) {
      return;
    }
    this.controller = controller;
    controller.on('markerClick', (marker: map.Marker): void => {
      if (this.disposed) {
        return;
      }
      const known: string | undefined = this.markerIds.get(marker.getId());
      this.events.onMarkerClick(known !== undefined ? known : marker.getId());
    });
    controller.on('cameraIdle', (): void => {
      if (this.disposed) {
        return;
      }
      const position: mapCommon.CameraPosition = controller.getCameraPosition();
      this.region = {
        latitude: position.target.latitude,
        longitude: position.target.longitude,
        zoom: position.zoom
      };
      this.events.onCameraIdle(this.region.latitude, this.region.longitude, this.region.zoom);
    });
    this.applyRegion();
    this.events.onReady();
  }

  handleMapError(error: BusinessError): void {
    // The map view failed to initialize (most often a missing/incorrect AGC AppKey). The overlay
    // stays unmounted and the managed side keeps the unavailable answers it already has; the
    // reason is logged here because the kit callback has no host channel of its own.
    hilog.error(DOMAIN, TAG, '%{public}s', `[maui] map overlay init failed: code=${error.code} ${error.message}`);
  }

  setRegion(region: MapOverlayRegion): void {
    this.region = region;
    this.applyRegion();
  }

  addMarker(marker: MapOverlayMarker): void {
    const controller = this.controller;
    if (controller === undefined || this.disposed) {
      return;
    }
    const options: mapCommon.MarkerOptions = {
      position: {
        latitude: marker.latitude,
        longitude: marker.longitude
      },
      title: marker.title,
      clickable: true
    };
    controller.addMarker(options).then((created: map.Marker): void => {
      if (!this.disposed) {
        this.markerIds.set(created.getId(), marker.id);
      }
    }).catch((markerError: BusinessError): void => {
      // A rejected marker (bad coordinates, kit not ready) leaves the map without it; the
      // managed side sees no marker event, matching the kit's asynchronous contract.
      hilog.warn(DOMAIN, TAG, '%{public}s', `[maui] map marker '${marker.id}' rejected: code=${markerError.code} ${markerError.message}`);
    });
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.controller = undefined;
    this.markerIds.clear();
    this.node.release();
  }

  // Moves the camera without animation: the map view is a direct response to a managed set-region
  // op, so an animation would queue a second movement the app did not ask for.
  private applyRegion(): void {
    const controller = this.controller;
    if (controller === undefined || this.disposed) {
      return;
    }
    const target: mapCommon.LatLng = {
      latitude: this.region.latitude,
      longitude: this.region.longitude
    };
    controller.moveCamera(map.newLatLng(target, this.region.zoom));
  }
}
