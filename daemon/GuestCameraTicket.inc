// Foreground still-camera ticket. A separate notification/upload contract keeps
// guest JPEGs out of the owner's uncorrelated /v1/cam_upload pathname.
namespace {
struct GuestStill {
    std::string owner, token;
    double deadline=0;
    int position=1;
    bool ended=false, stopped=false, handed=false;
    NSData *jpeg=nil;
};
std::mutex guestStillMutex;
std::shared_ptr<GuestStill> guestStill;
std::mutex stillCaptureMutex;
std::mutex screenSnapshotMutex;
std::mutex guestResourcesMutex;
std::mutex guestSystemMutex;
std::map<std::string,std::string> guestResources;
std::map<std::string,std::set<uint64_t>> guestCameraGenerations;
std::map<std::string,double> guestRecordingDeadlines;
double guest_clock() {
    static mach_timebase_info_data_t base=[] {mach_timebase_info_data_t b;mach_timebase_info(&b);return b;}();
    return double(mach_continuous_time())*base.numer/base.denom/1e9;
}
char *guest_camera_internal(const char *method,const char *path,const char *query,const char *body,int bodyLength,int *status) {
    using json=nlohmann::json;
    if(strcmp(path,"/v1/guest_camera_ticket")&&strcmp(path,"/v1/guest_camera_upload")&&strcmp(path,"/v1/guest_camera_stopped"))return nullptr;
    std::lock_guard<std::mutex> lock(guestStillMutex);
    auto state=guestStill;
    if(!state){*status=404;return strdup("{\"error\":\"no_capture\"}");}
    if(!strcmp(path,"/v1/guest_camera_ticket")) {
        if(strcmp(method,"GET")||state->ended||state->handed||guest_clock()>=state->deadline){*status=410;return strdup("{\"error\":\"capture_ended\"}");}
        state->handed=true;
        return strdup(json{{"ticket",state->token},{"remaining_ms",int(std::max(0.0,state->deadline-guest_clock())*1000)},{"position",state->position}}.dump().c_str());
    }
    char token[80]={};get_param(query,"ticket",token,sizeof token);
    if(strcmp(method,"POST")||state->token!=token){*status=403;return strdup("{\"error\":\"invalid_capture_ticket\"}");}
    if(!strcmp(path,"/v1/guest_camera_stopped")){state->stopped=true;return strdup("{\"ok\":true}");}
    if(state->ended||guest_clock()>=state->deadline||bodyLength<=0||bodyLength>32*1024*1024){*status=410;return strdup("{\"error\":\"capture_ended\"}");}
    state->jpeg=[NSData dataWithBytes:body length:bodyLength];return strdup("{\"ok\":true}");
}
}
