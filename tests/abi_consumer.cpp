#include "openvr_driver.h"
#include <dlfcn.h>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <cstddef>
#include <cmath>
struct Host final : vr::IVRServerDriverHost {
 unsigned updates=0, additions=0; uint32_t index=0; vr::DriverPose_t pose{};
 bool TrackedDeviceAdded(const char *serial,vr::ETrackedDeviceClass cls,vr::ITrackedDeviceServerDriver *p) override {
  assert(!std::strcmp(serial,"petplay-abi-test")); assert(cls==vr::TrackedDeviceClass_GenericTracker && p);additions++;return true;
 }
 void TrackedDevicePoseUpdated(uint32_t i,const vr::DriverPose_t &p,uint32_t size) override {assert(size==sizeof(p));updates++;index=i;pose=p;}
 void VsyncEvent(double) override {assert(false);}
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
struct Context final : vr::IVRDriverContext {
 Host host; bool available=true; unsigned requests=0;
 void *GetGenericInterface(const char *name,vr::EVRInitError *err) override {
  requests++;assert(!std::strcmp(name,vr::IVRServerDriverHost_Version));
  if(err)*err=available?vr::VRInitError_None:vr::VRInitError_Init_InterfaceNotFound;
  return available?&host:nullptr;
 }
 vr::DriverHandle_t GetDriverHandle() override {return UINT64_C(0xfedcba9876543210);}
};
template<class T> T symbol(void *lib,const char *name) {void *p=dlsym(lib,name);assert(p);return reinterpret_cast<T>(p);}
int main(int argc,char **argv) {
 assert(argc==2);void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){std::puts(dlerror());return 1;}
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
 assert(!std::strcmp(p->GetInterfaceVersions()[0],vr::IServerTrackedDeviceProvider_Version));
 assert(!std::strcmp(p->GetInterfaceVersions()[1],vr::ITrackedDeviceServerDriver_Version));
 assert(p->GetInterfaceVersions()[3]==nullptr);
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
 dlclose(lib);std::puts("PASS pure Zig: provider/device virtual calls, reverse context/host calls, DriverPose_t return/layout, native actor dispatch, lifecycle");
}
