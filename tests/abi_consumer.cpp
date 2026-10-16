#include "openvr_driver.h"
#include <dlfcn.h>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <cstddef>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <atomic>
#include <thread>
#include <chrono>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <set>
#include <linux/dma-buf.h>
#include <linux/sync_file.h>
struct Settings final : vr::IVRSettings {
 bool enabled=false, controllers=false, direct=false;
 const char *GetSettingsErrorNameFromEnum(vr::EVRSettingsError) override { return "test"; }
 void SetBool(const char*,const char*,bool,vr::EVRSettingsError*) override { assert(false); }
 void SetInt32(const char*,const char*,int32_t,vr::EVRSettingsError*) override { assert(false); }
 void SetFloat(const char*,const char*,float,vr::EVRSettingsError*) override { assert(false); }
 void SetString(const char*,const char*,const char*,vr::EVRSettingsError*) override { assert(false); }
 bool GetBool(const char *section,const char *key,vr::EVRSettingsError *err) override {
  assert(!std::strcmp(section,"driver_petplay"));
  if(err)*err=vr::VRSettingsError_None;
  if(!std::strcmp(key,"driverDirect"))return direct;
  if(!std::strcmp(key,"syntheticControllers"))return controllers;
  assert(!std::strcmp(key,"syntheticHmd"));return enabled;
 }
 int32_t GetInt32(const char*,const char*,vr::EVRSettingsError*) override { assert(false);return 0; }
 float GetFloat(const char*,const char*,vr::EVRSettingsError*) override { assert(false);return 0; }
 void GetString(const char *section,const char *key,char *out,uint32_t size,vr::EVRSettingsError *err) override {
  assert(!std::strcmp(section,"driver_petplay") && !std::strcmp(key,"socketDirectory") && size>0);
  out[0]=0;if(err)*err=vr::VRSettingsError_None;
 }
 void RemoveSection(const char*,vr::EVRSettingsError*) override { assert(false); }
 void RemoveKeyInSection(const char*,const char*,vr::EVRSettingsError*) override { assert(false); }
};
struct Properties final : vr::IVRProperties {
 unsigned writes=0; bool reject=false;
 vr::ETrackedPropertyError ReadPropertyBatch(vr::PropertyContainerHandle_t,vr::PropertyRead_t*,uint32_t) override { assert(false);return vr::TrackedProp_Success; }
 vr::ETrackedPropertyError WritePropertyBatch(vr::PropertyContainerHandle_t c,vr::PropertyWrite_t *batch,uint32_t count) override {
  assert(c>=123 && c<=126 && count==1);auto &b=*batch; assert(b.writeType==vr::PropertyWrite_Set && b.pvBuffer);
  if(reject)return vr::TrackedProp_InvalidOperation;
  switch(b.unTag) {
   case vr::k_unFloatPropertyTag: assert(b.unBufferSize==sizeof(float));if(b.prop==vr::Prop_DisplayFrequency_Float)assert(*static_cast<float*>(b.pvBuffer)==75);break;
   case vr::k_unInt32PropertyTag: assert(b.unBufferSize==sizeof(int32_t));break;
   case vr::k_unBoolPropertyTag: assert(b.unBufferSize==sizeof(bool));break;
   case vr::k_unUint64PropertyTag: assert(b.unBufferSize==sizeof(uint64_t));break;
   case vr::k_unStringPropertyTag: assert(b.unBufferSize==std::strlen(static_cast<char*>(b.pvBuffer))+1);break;
   default:assert(false);
  }
  b.eError=vr::TrackedProp_Success;writes++;return vr::TrackedProp_Success;
 }
 const char *GetPropErrorNameFromEnum(vr::ETrackedPropertyError) override { return "test"; }
 vr::PropertyContainerHandle_t TrackedDeviceToPropertyContainer(uint32_t i) override {assert(i<=3);return 123+i;}
};
struct Host final : vr::IVRServerDriverHost {
 std::atomic<unsigned> vsyncs{0}; std::atomic<unsigned> updates{0}; unsigned additions=0; vr::ITrackedDeviceServerDriver *hmd=nullptr, *redirect=nullptr; vr::ITrackedDeviceServerDriver *controllers[2]{}; std::atomic<unsigned> controllerUpdates[2]{}; bool reject=false; uint32_t index=0; vr::DriverPose_t pose{};
 bool TrackedDeviceAdded(const char *serial,vr::ETrackedDeviceClass cls,vr::ITrackedDeviceServerDriver *p) override {
  if(cls==vr::TrackedDeviceClass_Controller) {
   unsigned hand=!std::strcmp(serial,"PETPLAY-SYNTHETIC-LEFT-001")?0:1;
   assert(!std::strcmp(serial,hand==0?"PETPLAY-SYNTHETIC-LEFT-001":"PETPLAY-SYNTHETIC-RIGHT-001"));
   controllers[hand]=p;assert(p->Activate(2+hand)==0);additions++;return true;
  }
  if(cls==vr::TrackedDeviceClass_DisplayRedirect) {
   assert(!std::strcmp(serial,"PETPLAY-SYNTHETIC-DISPLAY-001"));redirect=p;assert(p->Activate(1)==0);additions++;return true;
  }
  if(cls==vr::TrackedDeviceClass_HMD) {
   assert(!std::strcmp(serial,"PETPLAY-SYNTHETIC-HMD-001"));if(reject)return false;
   hmd=p;assert(p->Activate(0)==0);additions++;return true;
  }
  assert(!std::strcmp(serial,"petplay-abi-test")); assert(cls==vr::TrackedDeviceClass_GenericTracker && p);additions++;return true;
 }
 void TrackedDevicePoseUpdated(uint32_t i,const vr::DriverPose_t &p,uint32_t size) override {assert(size==sizeof(p));if(i==2 || i==3){assert(p.poseIsValid && p.deviceIsConnected);assert(p.poseTimeOffset<=0 && p.poseTimeOffset>-.1);controllerUpdates[i-2]++;return;}index=i;pose=p;updates.fetch_add(1,std::memory_order_release);}
 void VsyncEvent(double offset) override {assert(std::isfinite(offset) && offset<=.002 && offset>-.1);vsyncs++;}
 void VendorSpecificEvent(uint32_t,vr::EVREventType,const vr::VREvent_Data_t&,double) override {assert(false);}
 bool IsExiting() override {return false;}
 bool PollNextEvent(vr::VREvent_t*,uint32_t) override {return false;}
 void GetRawTrackedDevicePoses(float,vr::TrackedDevicePose_t*,uint32_t) override {assert(false);}
 void RequestRestart(const char*,const char*,const char*,const char*) override {assert(false);}
 uint32_t GetFrameTimings(vr::Compositor_FrameTiming*,uint32_t) override {return 0;}
 void SetDisplayEyeToHead(uint32_t,const vr::HmdMatrix34_t&,const vr::HmdMatrix34_t&) override {assert(false);}
 void SetDisplayProjectionRaw(uint32_t,const vr::HmdRect2_t&,const vr::HmdRect2_t&) override {assert(false);}
 void SetRecommendedRenderTargetSize(uint32_t,uint32_t,uint32_t) override {assert(false);}
};
struct Input final : vr::IVRDriverInput {
 unsigned creates=0, updates=0;
 vr::EVRInputError CreateBooleanComponent(vr::PropertyContainerHandle_t c,const char *name,vr::VRInputComponentHandle_t *h) override { assert(c==125||c==126);assert(!std::strcmp(name,"/input/trigger/click"));*h=++creates;return vr::VRInputError_None; }
 vr::EVRInputError UpdateBooleanComponent(vr::VRInputComponentHandle_t h,bool value,double time) override {assert(h && !value && time==0);updates++;return vr::VRInputError_None;}
 vr::EVRInputError CreateScalarComponent(vr::PropertyContainerHandle_t c,const char *name,vr::VRInputComponentHandle_t *h,vr::EVRScalarType type,vr::EVRScalarUnits units) override {assert(c==125||c==126);assert(!std::strcmp(name,"/input/trigger/value") && type==vr::VRScalarType_Absolute && units==vr::VRScalarUnits_NormalizedOneSided);*h=++creates;return vr::VRInputError_None;}
 vr::EVRInputError UpdateScalarComponent(vr::VRInputComponentHandle_t h,float value,double time) override {assert(h && value==0 && time==0);updates++;return vr::VRInputError_None;}
 vr::EVRInputError CreateHapticComponent(vr::PropertyContainerHandle_t c,const char *name,vr::VRInputComponentHandle_t *h) override {assert(c==125||c==126);assert(!std::strcmp(name,"/output/haptic"));*h=++creates;return vr::VRInputError_None;}
 vr::EVRInputError CreateSkeletonComponent(vr::PropertyContainerHandle_t,const char*,const char*,const char*,vr::EVRSkeletalTrackingLevel,const vr::VRBoneTransform_t*,uint32_t,vr::VRInputComponentHandle_t*) override {assert(false);return vr::VRInputError_None;}
 vr::EVRInputError UpdateSkeletonComponent(vr::VRInputComponentHandle_t,vr::EVRSkeletalMotionRange,const vr::VRBoneTransform_t*,uint32_t) override {assert(false);return vr::VRInputError_None;}
 vr::EVRInputError CreatePoseComponent(vr::PropertyContainerHandle_t,const char*,vr::VRInputComponentHandle_t*) override {assert(false);return vr::VRInputError_None;}
 vr::EVRInputError UpdatePoseComponent(vr::VRInputComponentHandle_t,const vr::HmdMatrix34_t*,double) override {assert(false);return vr::VRInputError_None;}
 vr::EVRInputError CreateEyeTrackingComponent(vr::PropertyContainerHandle_t,const char*,vr::VRInputComponentHandle_t*) override {assert(false);return vr::VRInputError_None;}
 vr::EVRInputError UpdateEyeTrackingComponent(vr::VRInputComponentHandle_t,const vr::VREyeTrackingData_t*,double) override {assert(false);return vr::VRInputError_None;}
};
struct Resources final : vr::IVRIPCResourceManagerClient {
 unsigned imageCalls=0, failImage=0, unrefs=0; bool unavailable=false, failRef=false, failFd=false;
 uint64_t nextHandle=1000;std::set<uint64_t> live;std::vector<int> fds;
 bool NewSharedVulkanImage(uint32_t format,uint32_t w,uint32_t h,bool render,bool map,bool compute,uint32_t mips,uint32_t layers,uint32_t flags,uint32_t usage,vr::SharedTextureHandle_t *out) override {
  assert(format==43 && w==640 && h==640 && render && !map && compute && mips==1 && layers==1 && flags==8 && usage==0x85);
  if(++imageCalls==failImage)return false;
  *out=++nextHandle;live.insert(*out);return true;
 }
 bool NewSharedVulkanBuffer(uint32_t,uint32_t,vr::SharedTextureHandle_t*) override {assert(false);return false;}
 bool NewSharedVulkanSemaphore(bool,vr::SharedTextureHandle_t*) override {assert(false);return false;}
 bool RefResource(vr::SharedTextureHandle_t h,uint64_t *out) override {assert(live.count(h));if(failRef)return false;*out=h;return true;}
 bool UnrefResource(vr::SharedTextureHandle_t h) override {assert(live.erase(h)==1);unrefs++;return true;}
 bool GetDmabufFormats(uint32_t*,uint32_t*) override {assert(false);return false;}
 bool GetDmabufModifiers(vr::EVRApplicationType,uint32_t,uint32_t*,uint64_t*) override {assert(false);return false;}
 bool ImportDmabuf(vr::EVRApplicationType,vr::DmabufAttributes_t*,vr::SharedTextureHandle_t*) override {assert(false);return false;}
 bool ReceiveSharedFd(uint64_t h,int *fd) override {assert(live.count(h));if(failFd)return false;*fd=open("/dev/null",O_RDONLY|O_CLOEXEC);assert(*fd>=0);fds.push_back(*fd);return true;}
};
struct DriverLog final : vr::IVRDriverLog { unsigned calls=0; void Log(const char *text) override { assert(text && *text);calls++; } };
struct Context final : vr::IVRDriverContext {
 Host host; Resources resources; Input input; DriverLog log; Settings settings; Properties properties; bool available=true; unsigned requests=0;
 void *GetGenericInterface(const char *name,vr::EVRInitError *err) override {
  if(!std::strcmp(name,vr::IVRIPCResourceManagerClient_Version)) {if(err)*err=resources.unavailable?vr::VRInitError_Init_InterfaceNotFound:vr::VRInitError_None;return resources.unavailable?nullptr:&resources;}
  if(!std::strcmp(name,vr::IVRDriverInput_Version)) {if(err)*err=vr::VRInitError_None;return &input;}
  if(!std::strcmp(name,vr::IVRDriverLog_Version)) {if(err)*err=vr::VRInitError_None;return &log;}
  if(!std::strcmp(name,vr::IVRSettings_Version)) {if(err)*err=vr::VRInitError_None;return &settings;}
  if(!std::strcmp(name,vr::IVRProperties_Version)) {if(err)*err=vr::VRInitError_None;return &properties;}
  requests++;assert(!std::strcmp(name,vr::IVRServerDriverHost_Version));
  if(err)*err=available?vr::VRInitError_None:vr::VRInitError_Init_InterfaceNotFound;
  return available?&host:nullptr;
 }
 vr::DriverHandle_t GetDriverHandle() override {return UINT64_C(0xfedcba9876543210);}
};
template<class T> T symbol(void *lib,const char *name) {void *p=dlsym(lib,name);assert(p);return reinterpret_cast<T>(p);}
int main(int argc,char **argv) {
 assert(argc==2 || argc==4);void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){std::puts(dlerror());return 1;}
 char temporary[]="/tmp/petplay-driver-abi-XXXXXX";
 const char *directory = argc==4 ? argv[3] : mkdtemp(temporary);assert(directory);
 assert(symbol<bool(*)(const char*)>(lib,"pp_test_set_directory")(directory));
 auto factory=symbol<void*(*)(const char*,int*)>(lib,"HmdDriverFactory");
 int err=-1;assert(!factory(nullptr,&err)&&err==105);assert(!factory("unknown",&err)&&err==105);
 auto *p=static_cast<vr::IServerTrackedDeviceProvider*>(factory(vr::IServerTrackedDeviceProvider_Version,&err));assert(p&&err==0);
 auto ticks=symbol<uint64_t(*)()>(lib,"pp_test_ticks");
 auto initialized=symbol<bool(*)()>(lib,"pp_test_initialized");
 auto standby=symbol<bool(*)()>(lib,"pp_test_standby");
 assert(p->Init(nullptr)==vr::VRInitError_Driver_Failed);assert(!initialized());
 Context ctx;ctx.available=false;assert(p->Init(&ctx)==vr::VRInitError_Init_InterfaceNotFound);assert(!initialized());
 ctx.available=true;assert(p->Init(&ctx)==0);assert(ctx.requests==2 && initialized());
 assert(symbol<uint64_t(*)()>(lib,"pp_test_handle")()==UINT64_C(0xfedcba9876543210));
 assert(p->Init(&ctx)==vr::VRInitError_Driver_Failed); // Duplicate lifecycle must not leak/reset context.
 if(argc==4) {
  if(!std::strcmp(argv[2],"--expect-no-ipc")) {
   assert(!symbol<bool(*)()>(lib,"pp_test_ipc_listening")());p->Cleanup();dlclose(lib);std::puts("IPC_UNAVAILABLE");return 0;
  }
  assert(!std::strcmp(argv[2],"--serve"));assert(symbol<bool(*)()>(lib,"pp_test_ipc_listening")());
  p->RunFrame();p->RunFrame();p->RunFrame();std::puts("READY");std::fflush(stdout);
  assert(std::getchar()=='q');p->Cleanup();assert(!initialized());
  std::puts("CLEANED");std::fflush(stdout);dlclose(lib);return 0;
 }
 assert(!std::strcmp(p->GetInterfaceVersions()[0],vr::IServerTrackedDeviceProvider_Version));
 assert(!std::strcmp(p->GetInterfaceVersions()[1],vr::ITrackedDeviceServerDriver_Version));
 assert(!std::strcmp(p->GetInterfaceVersions()[3],vr::IVRDisplayComponent_Version));
 assert(!std::strcmp(p->GetInterfaceVersions()[4],vr::IVRVirtualDisplay_Version));assert(!std::strcmp(p->GetInterfaceVersions()[5],"IVRDisplayComponent_002"));assert(!std::strcmp(p->GetInterfaceVersions()[6],vr::IVRCompositorPluginProvider_Version));assert(!std::strcmp(p->GetInterfaceVersions()[7],vr::IVRDriverDirectModeComponent_Version));assert(!std::strcmp(p->GetInterfaceVersions()[8],vr::IVRIPCResourceManagerClient_Version));assert(p->GetInterfaceVersions()[9]==nullptr);
 p->RunFrame();p->RunFrame();p->RunFrame();assert(ticks()==3);
 assert(!p->ShouldBlockStandbyMode());p->EnterStandby();assert(standby());p->LeaveStandby();assert(!standby());
 assert(symbol<size_t(*)()>(lib,"pp_test_pose_size")()==sizeof(vr::DriverPose_t));
 assert(symbol<size_t(*)()>(lib,"pp_test_pose_align")()==alignof(vr::DriverPose_t));
 assert(symbol<size_t(*)()>(lib,"pp_test_pose_position_offset")()==offsetof(vr::DriverPose_t,vecPosition));
 assert(symbol<size_t(*)()>(lib,"pp_test_pose_result_offset")()==offsetof(vr::DriverPose_t,result));
 auto *device=symbol<vr::ITrackedDeviceServerDriver*(*)()>(lib,"pp_test_device")();
 assert(device->Activate(7)==vr::VRInitError_Driver_Failed);device->Deactivate();device->EnterStandby();
 assert(!device->GetComponent("anything"));
 const auto pose=device->GetPose();assert(pose.vecPosition[1]==3.25 && pose.vecVelocity[0]==1.25 && pose.poseTimeOffset==-.0125);
 assert(pose.qRotation.w==1 && pose.qWorldFromDriverRotation.w==1 && pose.poseIsValid && !pose.deviceIsConnected);
 assert(symbol<bool(*)()>(lib,"pp_test_host_add")());assert(ctx.host.additions==1);
 symbol<void(*)(uint32_t)>(lib,"pp_test_host_pose")(37);assert(ctx.host.updates==1&&ctx.host.index==37&&ctx.host.pose.vecPosition[1]==3.25);
 char output[16385];
 device->DebugRequest(R"({"kind":"message","data":{"address":{"fm":"SYSTEM","to":"WORKER"},"type":"INIT","payload":{"actorId":"driver@00000000-0000-0000-0000-000000000001","callbackKey":"native-test"}}})",output,sizeof(output));
 assert(std::strstr(output,"LOADED")&&std::strstr(output,"native-test"));
 device->DebugRequest(R"({"kind":"message","data":{"address":{"fm":"test@x","to":"driver@00000000-0000-0000-0000-000000000001"},"type":"HEALTH:one","payload":null}})",output,sizeof(output));
 assert(std::strstr(output,"\"driverInitialized\":true")&&std::strstr(output,"\"runFrameCount\":3"));
 device->DebugRequest("{bad json",output,sizeof(output));assert(output[0]==0);
 char tiny[1]={'x'};device->DebugRequest("{}",tiny,1);assert(tiny[0]==0);device->DebugRequest("{}",tiny,0);
 p->Cleanup();assert(!initialized());p->RunFrame();assert(ticks()==3);
 assert(p->Init(&ctx)==0);assert(ticks()==0);p->Cleanup();
 // Opt-in HMD: official-header virtual dispatch, property buffers, both eyes and aggregate return.
 ctx.settings.enabled=true;ctx.host.updates=0;assert(p->Init(&ctx)==0);
 auto *hmd=ctx.host.hmd;assert(hmd && ctx.properties.writes==14);
 assert(hmd->Activate(0)==vr::VRInitError_Driver_Failed);
 auto *display=static_cast<vr::IVRDisplayComponent*>(hmd->GetComponent(vr::IVRDisplayComponent_Version));assert(display);
 assert(!hmd->GetComponent("IVRDisplayComponent_999"));
 assert(hmd->GetComponent("IVRDisplayComponent_002")==display);
 int32_t x,y;uint32_t w,h,ux,uy;display->GetWindowBounds(&x,&y,&w,&h);assert(x==0 && y==0 && w==1280 && h==720);
 assert(display->IsDisplayOnDesktop() && !display->IsDisplayRealDisplay());
 display->GetRecommendedRenderTargetSize(&w,&h);assert(w==640 && h==640);
 for(auto eye:{vr::Eye_Left,vr::Eye_Right}) {
  display->GetEyeOutputViewport(eye,&ux,&uy,&w,&h);assert(ux==(eye==vr::Eye_Left?0:640) && uy==0 && w==640 && h==720);
  float l,r,t,b;display->GetProjectionRaw(eye,&l,&r,&t,&b);assert(l==-1 && r==1 && t==-1 && b==1);
  auto d=display->ComputeDistortion(eye,.23f,.67f);assert(d.rfRed[0]==.23f && d.rfGreen[1]==.67f && d.rfBlue[0]==.23f);
  vr::HmdVector2_t v;assert(display->ComputeInverseDistortion(&v,eye,2,.31f,.78f));assert(v.v[0]==.31f && v.v[1]==.78f);
  assert(!display->ComputeInverseDistortion(&v,eye,3,0,0));
 }
 auto *sink=static_cast<vr::IVRVirtualDisplay*>(ctx.host.redirect->GetComponent(vr::IVRVirtualDisplay_Version));assert(sink);
 float seconds;uint64_t frame,after;assert(sink->GetTimeSinceLastVsync(&seconds,&frame));
 vr::PresentInfo_t info{};info.nFrameId=987;info.flVSyncTimeInSeconds=123.5;sink->Present(&info,sizeof(info));
 sink->WaitForPresent();assert(sink->GetTimeSinceLastVsync(&seconds,&after));assert(after>frame && seconds>=0 && seconds<1.f/75);
 // Clock count continues without Present callbacks (and skips missed frames).
 std::this_thread::sleep_for(std::chrono::milliseconds(35));assert(sink->GetTimeSinceLastVsync(&seconds,&frame));assert(frame>=after+2);
 p->Cleanup();assert(ctx.host.updates.load()>=2);assert(ctx.host.index==0 && ctx.host.pose.vecPosition[1]==1.6);
 auto previous=ctx.host.updates.load();std::this_thread::sleep_for(std::chrono::milliseconds(10));assert(ctx.host.updates==previous);
 // Compositor provider is independently initialized, with no server/IPC lifecycle.
 auto *plugin=static_cast<vr::IVRCompositorPluginProvider*>(factory(vr::IVRCompositorPluginProvider_Version,&err));assert(plugin && err==0);
 assert(!plugin->GetComponent(vr::IVRVirtualDisplay_Version));assert(plugin->Init(nullptr)==vr::VRInitError_Driver_Failed);
 assert(plugin->Init(&ctx)==0);assert(plugin->Init(&ctx)==vr::VRInitError_Driver_Failed);
 auto *pluginSink=static_cast<vr::IVRVirtualDisplay*>(plugin->GetComponent(vr::IVRVirtualDisplay_Version));assert(pluginSink);
 assert(!plugin->GetComponent("unknown"));assert(pluginSink->GetTimeSinceLastVsync(&seconds,&frame));
 pluginSink->WaitForPresent();assert(pluginSink->GetTimeSinceLastVsync(&seconds,&after) && after>frame);
 assert(ctx.log.calls>=3);plugin->Cleanup();assert(!plugin->GetComponent(vr::IVRVirtualDisplay_Version));
 ctx.settings.enabled=false;assert(plugin->Init(&ctx)==vr::VRInitError_Driver_Failed);ctx.settings.enabled=true;
 // Controllers are separately opt-in. Verify real official-header input calls and safe deactivation.
 ctx.settings.controllers=true;assert(p->Init(&ctx)==0);assert(ctx.host.controllers[0] && ctx.host.controllers[1]);
 assert(ctx.input.creates==6 && ctx.input.updates==4);
 for(unsigned hand=0;hand<2;hand++) {
  auto *c=ctx.host.controllers[hand];auto pose=c->GetPose();assert(pose.poseIsValid && pose.vecPosition[0]==(hand==0?-.25:.25));
 }
 device->DebugRequest(R"({"kind":"message","data":{"address":{"fm":"test@x","to":"driver@00000000-0000-0000-0000-000000000001"},"type":"SETCONTROLLERMOTION","payload":{"mode":"sine"}}})",output,sizeof(output));assert(output[0]==0);
 std::this_thread::sleep_for(std::chrono::milliseconds(20));assert(std::abs(ctx.host.controllers[0]->GetPose().vecVelocity[0])>.01);assert(ctx.host.controllerUpdates[0]>=2 && ctx.host.controllerUpdates[1]>=2);
 ctx.host.controllers[0]->Deactivate();auto leftCount=ctx.host.controllerUpdates[0].load();
 assert(!ctx.host.controllers[0]->GetPose().deviceIsConnected);
 std::this_thread::sleep_for(std::chrono::milliseconds(12));assert(ctx.host.controllerUpdates[0]==leftCount);
 p->Cleanup();auto rightCount=ctx.host.controllerUpdates[1].load();std::this_thread::sleep_for(std::chrono::milliseconds(10));assert(ctx.host.controllerUpdates[1]==rightCount);
 ctx.settings.controllers=false;
 auto fenceLayout=symbol<size_t(*)(uint32_t)>(lib,"pp_test_fence_layout");
 assert(fenceLayout(0)==sizeof(dma_buf_export_sync_file) && fenceLayout(1)==sizeof(sync_file_info) && fenceLayout(2)==sizeof(sync_fence_info) && fenceLayout(3)==offsetof(sync_file_info,sync_fence_info));
 // Driver-direct ABI and real allocation protocol, including rollback and resource retry.
 ctx.settings.direct=true;ctx.host.redirect=nullptr;assert(p->Init(&ctx)==0);assert(!ctx.host.redirect);
 auto *dm=static_cast<vr::IVRDriverDirectModeComponent*>(ctx.host.hmd->GetComponent(vr::IVRDriverDirectModeComponent_Version));assert(dm);
 display=static_cast<vr::IVRDisplayComponent*>(ctx.host.hmd->GetComponent(vr::IVRDisplayComponent_Version));assert(!display->IsDisplayOnDesktop());
 auto layout=symbol<size_t(*)(uint32_t)>(lib,"pp_test_direct_layout");
 assert(layout(0)==sizeof(vr::IVRDriverDirectModeComponent::SwapTextureSet_t));
 assert(layout(1)==sizeof(vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t));
 assert(layout(2)==offsetof(vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t,mHmdPose));
 assert(layout(3)==offsetof(vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t,flHmdPosePredictionTimeInSecondsFromNow));
 vr::IVRDriverDirectModeComponent::SwapTextureSetDesc_t desc{640,640,43,1};
 vr::IVRDriverDirectModeComponent::SwapTextureSet_t set{};
 ctx.resources.unavailable=true;dm->CreateSwapTextureSet(42,&desc,&set);assert(set.rSharedTextureHandles[0]==0);
 ctx.resources.unavailable=false;ctx.resources.failImage=2;dm->CreateSwapTextureSet(42,&desc,&set);assert(set.rSharedTextureHandles[0]==0 && ctx.resources.live.empty());
 ctx.resources.failImage=0;ctx.resources.failRef=true;dm->CreateSwapTextureSet(42,&desc,&set);assert(set.rSharedTextureHandles[0]==0 && ctx.resources.live.empty());
 ctx.resources.failRef=false;ctx.resources.failFd=true;dm->CreateSwapTextureSet(42,&desc,&set);assert(set.rSharedTextureHandles[0]==0 && ctx.resources.live.empty());ctx.resources.failFd=false;
 dm->CreateSwapTextureSet(42,&desc,&set);assert(set.rSharedTextureHandles[0] && set.unTextureFlags==0 && ctx.resources.live.size()==3);
 vr::SharedTextureHandle_t handles[2]{set.rSharedTextureHandles[0],set.rSharedTextureHandles[1]};uint32_t indices[2]{};
 dm->GetNextSwapTextureSetIndex(handles,&indices);assert(indices[0]==1 && indices[1]==1);
 dm->GetNextSwapTextureSetIndex(handles,&indices);assert(indices[0]==2 && indices[1]==2);
 vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t eyes[2]{};
 for(unsigned i=0;i<2;i++){eyes[i].hTexture=handles[i];eyes[i].bounds={.1f,.2f,.8f,.9f};eyes[i].mHmdPose.m[1][3]=1.6f;eyes[i].flHmdPosePredictionTimeInSecondsFromNow=.015f;}
 dm->SubmitLayer(eyes);dm->SubmitLayer(eyes);dm->Present(12345);dm->PostPresent(nullptr);
 vr::DriverDirectMode_FrameTiming ft{sizeof(ft),99,99,99,0xffffffff};dm->GetFrameTiming(&ft);assert(ft.m_nNumFramePresents==1 && !ft.m_nNumMisPresented && !ft.m_nNumDroppedFrames && !ft.m_nReprojectionFlags);
 ft={sizeof(ft)-1,99,99,99,99};dm->GetFrameTiming(&ft);assert(ft.m_nNumFramePresents==99 && ft.m_nReprojectionFlags==99);
 dm->DestroySwapTextureSet(handles[1]);assert(ctx.resources.live.empty());
 for(int fd:ctx.resources.fds)assert(fcntl(fd,F_GETFD)==-1);ctx.resources.fds.clear();
 dm->DestroySwapTextureSet(handles[0]);dm->CreateSwapTextureSet(42,&desc,&set);dm->DestroyAllSwapTextureSets(99);assert(ctx.resources.live.size()==3);
 dm->DestroyAllSwapTextureSets(42);assert(ctx.resources.live.empty());
 dm->CreateSwapTextureSet(42,&desc,&set);assert(ctx.resources.live.size()==3);
 p->Cleanup();assert(ctx.resources.live.empty());auto vsyncCount=ctx.host.vsyncs.load();assert(vsyncCount>0);
 std::this_thread::sleep_for(std::chrono::milliseconds(20));assert(ctx.host.vsyncs==vsyncCount);
 for(int fd:ctx.resources.fds)assert(fcntl(fd,F_GETFD)==-1);
 ctx.settings.direct=false;
 // Registration rejection must not leak a device/pose thread.
 ctx.host.reject=true;ctx.host.hmd=nullptr;assert(p->Init(&ctx)==0);assert(!ctx.host.hmd);p->Cleanup();
 std::filesystem::remove_all(directory);dlclose(lib);std::puts("PASS pure Zig: provider/device virtual calls, reverse context/host calls, DriverPose_t return/layout, native actor dispatch, lifecycle");
}
