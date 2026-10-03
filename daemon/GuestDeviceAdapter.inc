// In-process guest adapter. Only explicit operation names can reach device
// functions; this is never a guest HTTP proxy or a prefix-based URL allowlist.
namespace {
using GuestJSON = nlohmann::json;
static std::string guest_text(const GuestJSON &args,const char *key,size_t limit=1024) {
    if(!args.contains(key)||!args[key].is_string())throw std::runtime_error("invalid_argument");
    auto value=args[key].get<std::string>();
    if(value.size()>limit||value.find('\0')!=std::string::npos)throw std::runtime_error("invalid_argument");return value;
}
static bool guest_bool(const GuestJSON &args,const char *key) {
    if(!args.contains(key)||!args[key].is_boolean())throw std::runtime_error("boolean_required");return args[key].get<bool>();
}
static void guest_current(const char *owner,double deadline) {
    if(guest_clock()>=deadline || !rctl_webrtc_guest_operations_current(owner))throw std::runtime_error("access_ended");
}
static char *guest_sb(const char *owner,double deadline,const char *operation,const GuestJSON &args,int *status) {
    auto value=GuestJSON{{"owner",owner},{"deadline",deadline},{"operation",operation},{"args",args}}.dump();
    char *result=sb_query(RCTL_Q_GUEST_COMMAND,value.data(),value.size(),3.0);
    if(!result){*status=504;return strdup("{\"error\":\"device_timeout\"}");}return result;
}
static char *guest_device_action(const char *owner,double deadline,const char *operation,const char *arguments,int *status,int *length,const char **contentType) {
    try {
        const auto args=GuestJSON::parse(arguments);const std::string op(operation);
        if(op=="session.cancel") {
            bool cancel=false;
            {std::lock_guard<std::mutex> lock(guestStillMutex);if(guestStill&&guestStill->owner==owner){guestStill->ended=true;guestStill->jpeg=nil;cancel=true;}}
            if(cancel)notify_post("com.greatlove.rctl.cam.guest.cancel");on_guest_end(owner,false);
            return strdup("{\"ok\":true}");
        }
        if(op=="session.end") {
            std::shared_ptr<GuestStill> still;
            {std::lock_guard<std::mutex> lock(guestStillMutex);if(guestStill&&guestStill->owner==owner){still=guestStill;still->ended=true;still->jpeg=nil;}}
            {std::lock_guard<std::mutex> lock(guestResourcesMutex);
            for(auto it=guestResources.begin();it!=guestResources.end();) {
                if(it->second!=owner){++it;continue;}
                if(it->first=="playback")audio_capture_set(false,nullptr,0);
                if(it->first=="microphone"){g_micListenWant=false;rctl_mic_refresh();}
                if(it->first=="mic-record"){guestRecordingDeadlines.erase("mic-record");rctl_mic_record_stop();g_micRecordWant=false;unlink(RCTL_MIC_REC_PATH);rctl_mic_refresh();}
                if(it->first=="camera"){rctl_camera_record_discard();rctl_camera_set_active(false);dispatch_sync(gAuto,^{gCameraLive=false;apply_active();});}
                if(it->first=="camera-record"){guestRecordingDeadlines.erase("camera-record");rctl_camera_record_discard();}
                if(it->first=="camera"||it->first=="output") {++it;continue;} // Release only after app stop acknowledgement.
                it=guestResources.erase(it);
            }}
            {
                std::lock_guard<std::mutex> lock(guestResourcesMutex);
                auto generations=guestCameraGenerations.find(owner);
                if(generations!=guestCameraGenerations.end()) {
                    for(auto generation:generations->second)if(!rctl_camera_generation_retired(generation)) {
                        *status=503;return strdup("{\"error\":\"camera_cleanup_unconfirmed\"}");
                    }
                    guestCameraGenerations.erase(generations);
                }
                auto camera=guestResources.find("camera");if(camera!=guestResources.end()&&camera->second==owner)guestResources.erase(camera);
            }
            if(still) {
                notify_post("com.greatlove.rctl.cam.guest.cancel");double until=guest_clock()+0.7;bool stopped=false;
                while(guest_clock()<until){{std::lock_guard<std::mutex> lock(guestStillMutex);stopped=still->stopped||!still->handed;}if(stopped)break;usleep(5000);}
                if(!stopped){*status=503;return strdup("{\"error\":\"camera_cleanup_unconfirmed\"}");}
                {std::lock_guard<std::mutex> lock(guestStillMutex);if(guestStill==still)guestStill.reset();}
            }
            // Fence queued owned SpringBoard work before reporting retirement.
            if(!on_guest_end(owner,true)){*status=503;return strdup("{\"error\":\"springboard_cleanup_unconfirmed\"}");}
            {std::lock_guard<std::mutex> lock(guestResourcesMutex);auto output=guestResources.find("output");if(output!=guestResources.end()&&output->second==owner)guestResources.erase(output);}
            return strdup("{\"ok\":true}");
        }
        if(op=="capture.status") {
            std::lock_guard<std::mutex> lock(guestResourcesMutex);
            pthread_mutex_lock(&g_recLock);const bool micRecording=g_recording;pthread_mutex_unlock(&g_recLock);
            std::unique_ptr<char,decltype(&free)> cameraStatus(rctl_camera_status_json(),free);
            const bool cameraRecording=cameraStatus&&GuestJSON::parse(cameraStatus.get()).value("recording",false);
            GuestJSON result=GuestJSON::object();
            for(const auto &entry:{std::pair<const char*,const char*>("microphone","mic-record"),{"camera","camera-record"}}) {
                auto resource=guestResources.find(entry.second);auto limit=guestRecordingDeadlines.find(entry.second);
                result[entry.first]=resource!=guestResources.end()&&resource->second==owner&&limit!=guestRecordingDeadlines.end()&&guest_clock()<limit->second&&(std::string(entry.first)=="microphone"?micRecording:cameraRecording);
            }
            return strdup(result.dump().c_str());
        }
        if(op=="device.info") {
            std::unique_ptr<char,decltype(&free)> raw(guest_sb(owner,deadline,operation,args,status),free);
            auto all=GuestJSON::parse(raw.get());GuestJSON safe=GuestJSON::object();
            for(const char *key:{"model","model_id","ios","build","battery","battery_state","brightness","cpu","memory","storage","uptime"})if(all.contains(key))safe[key]=all[key];
            return strdup(safe.dump().c_str());
        }
        if(op=="clipboard.read"||op=="apps.list")return guest_sb(owner,deadline,operation,args,status);
        if(op=="input.text") {
            auto value=guest_text(args,"text",256);
            for(unsigned char letter:value) {int shift;if(!ascii_to_hid(letter,&shift))throw std::runtime_error("only_us_keyboard_text_supported");}
            for(unsigned char letter:value) {
                int shift;int usage=ascii_to_hid(letter,&shift);
                if(shift&&!rctl_webrtc_guest_text_key(owner,0xe1,1))throw std::runtime_error("input_in_use");
                if(!rctl_webrtc_guest_text_key(owner,usage,1)) {if(shift)rctl_webrtc_guest_text_key(owner,0xe1,0);throw std::runtime_error("input_in_use");}
                usleep(12000);rctl_webrtc_guest_text_key(owner,usage,0);
                if(shift)rctl_webrtc_guest_text_key(owner,0xe1,0);
                usleep(12000);
            }
            return strdup("{\"ok\":true}");
        }
        if(op=="input.pointer") {
            auto action=guest_text(args,"action",16);
            if(action!="acquire"&&action!="release"&&action!="state"&&action!="move")throw std::runtime_error("invalid_pointer_action");
            if(args.contains("owner"))throw std::runtime_error("caller_owner_forbidden");
            return guest_sb(owner,deadline,operation,args,status);
        }
        if(op=="clipboard.write") {guest_text(args,"text",4096);return guest_sb(owner,deadline,operation,args,status);}
        if(op=="device.brightness") {
            if(!args.contains("value")||!args["value"].is_number()||!std::isfinite(args["value"].get<double>())||args["value"]<0||args["value"]>1)throw std::runtime_error("brightness_out_of_range");
            return guest_sb(owner,deadline,operation,args,status);
        }
        if(op=="device.orientation") {
            if(!args.contains("orientation")||!args["orientation"].is_number_integer()||args["orientation"]<0||args["orientation"]>4)throw std::runtime_error("invalid_orientation");
            return guest_sb(owner,deadline,operation,args,status);
        }
        if(op=="apps.launch") {
            auto bundle=guest_text(args,"bundle",256);
            if(bundle.empty()||bundle.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")!=std::string::npos)throw std::runtime_error("invalid_bundle");
            return guest_sb(owner,deadline,operation,args,status);
        }
        if(op=="apps.open_url") {
            auto value=guest_text(args,"url",1024);NSURLComponents *url=[NSURLComponents componentsWithString:@(value.c_str())];
            if(!url.host.length||url.user||url.password||(![url.scheme.lowercaseString isEqualToString:@"https"]&&![url.scheme.lowercaseString isEqualToString:@"http"]))throw std::runtime_error("web_url_required");
            return guest_sb(owner,deadline,operation,args,status);
        }
        if(op=="system.tweak_toggle"||op=="system.package_download") {
            std::lock_guard<std::mutex> lock(guestSystemMutex);
            guest_current(owner,deadline);
            auto name=guest_text(args,"name",160);
            if(name.empty()||name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")!=std::string::npos||name.find("..")!=std::string::npos||name.rfind("rctl",0)==0)throw std::runtime_error("invalid_tweak");
            NSString *root=RCTL_ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries");
            if(op=="system.tweak_toggle") {
                const bool enabled=guest_bool(args,"enabled");
                int dir=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
                if(dir<0)throw std::runtime_error("tweak_unavailable");
                std::unique_ptr<int,std::function<void(int*)>> directory(&dir,[](int *fd){close(*fd);});
                auto dylib=name+".dylib",plist=name+".plist";
                const std::string suffix=enabled?".disabled":"",targetSuffix=enabled?"":".disabled";
                struct stat st={};
                auto regular=[&](const std::string &file){return !fstatat(dir,file.c_str(),&st,AT_SYMLINK_NOFOLLOW)&&S_ISREG(st.st_mode)&&st.st_nlink==1;};
                if(regular(dylib+targetSuffix)&&regular(plist+targetSuffix))return strdup("{\"ok\":true}");
                if(!regular(dylib+suffix)||!regular(plist+suffix)||!fstatat(dir,(dylib+targetSuffix).c_str(),&st,AT_SYMLINK_NOFOLLOW)||!fstatat(dir,(plist+targetSuffix).c_str(),&st,AT_SYMLINK_NOFOLLOW))throw std::runtime_error("tweak_state_conflict");
                if(renameat(dir,(dylib+suffix).c_str(),dir,(dylib+targetSuffix).c_str()))throw std::runtime_error("tweak_change_failed");
                if(renameat(dir,(plist+suffix).c_str(),dir,(plist+targetSuffix).c_str())) {
                    if(renameat(dir,(dylib+targetSuffix).c_str(),dir,(dylib+suffix).c_str()))throw std::runtime_error("tweak_recovery_required");
                    throw std::runtime_error("tweak_change_failed");
                }
                fsync(dir);return strdup("{\"ok\":true}");
            }
            int dir=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            int fd=dir<0?-1:openat(dir,(name+".dylib").c_str(),O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(dir>=0)close(dir);
            struct stat st={};if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1){if(fd>=0)close(fd);throw std::runtime_error("tweak_unavailable");}
            return strdup(GuestJSON{{"_guest_fd",fd},{"name",name+".dylib"}}.dump().c_str());
        }
        if(op=="system.package_remove") {
            std::lock_guard<std::mutex> lock(guestSystemMutex);
            guest_current(owner,deadline);
            auto id=guest_text(args,"id",160);
            if(!rctl_safe_id(id.c_str())||id=="com.greatlove.rctl"||id=="dpkg"||id=="apt"||id=="firmware"||id=="ellekit"||id=="mobilesubstrate"||id=="openssh")throw std::runtime_error("protected_package");
            NSString *raw=[NSString stringWithContentsOfFile:RCTL_ROOT_PATH_NS(@"/var/lib/dpkg/status") encoding:NSUTF8StringEncoding error:nil];
            bool installed=false;
            for(NSString *stanza in [raw componentsSeparatedByString:@"\n\n"]) {
                NSString *prefix=[NSString stringWithFormat:@"Package: %s\n",id.c_str()];
                if([stanza hasPrefix:prefix]) {
                    if([stanza containsString:@"Essential: yes"]||[stanza containsString:@"Priority: required"])throw std::runtime_error("protected_package");
                    installed=[stanza containsString:@"Status: install ok installed"];break;
                }
            }
            if(!installed)throw std::runtime_error("package_not_installed");
            // Once dpkg starts, package-manager recovery takes precedence over
            // aborting its process. Retirement stays unconfirmed until it exits.
            std::unique_ptr<char,decltype(&free)> removed(rctl_pkg_remove(id.c_str()),free);
            if(!removed)throw std::runtime_error("package_remove_failed");
            auto result=GuestJSON::parse(removed.get());
            if(result.contains("output")&&result["output"].is_string())result["output"]=result["output"].get<std::string>().substr(0,16384);
            return strdup(result.dump().c_str());
        }
        if(op=="system.respring") {respring_device();return strdup("{\"ok\":true}");}
        if(op=="capture.download") {
            auto kind=guest_text(args,"kind",16);
            const char *path=kind=="microphone"?RCTL_MIC_REC_PATH:kind=="camera"?RCTL_CAMERA_RECORD_PATH:nullptr;
            std::lock_guard<std::mutex> lock(guestResourcesMutex);
            auto it=guestResources.find(kind=="microphone"?"mic-record":"camera-record");
            if(!path||it==guestResources.end()||it->second!=owner)throw std::runtime_error("capture_not_owned");
            if(kind=="microphone"){rctl_mic_record_stop();g_micRecordWant=false;rctl_mic_refresh();}else rctl_camera_record_stop();
            int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);struct stat st={};
            if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)){if(fd>=0)close(fd);throw std::runtime_error("capture_unavailable");}
            guestRecordingDeadlines.erase(kind=="microphone"?"mic-record":"camera-record");
            return strdup(GuestJSON{{"_guest_fd",fd},{"name",kind=="microphone"?"microphone.m4a":"camera.ts"}}.dump().c_str());
        }
        if(op=="audio.output") {
            const bool enabled=guest_bool(args,"enabled");
            std::lock_guard<std::mutex> lock(guestResourcesMutex);guest_current(owner,deadline);
            auto output=guestResources.find("output");if(output!=guestResources.end()&&output->second!=owner)throw std::runtime_error("resource_in_use");
            guestResources["output"]=owner;
            return guest_sb(owner,deadline,operation,{{"enabled",enabled}},status);
        }
        if(op=="talk.route") {
            auto mode=guest_text(args,"mode",8);
            int route=mode=="speaker"?RCTL_TALK_SPEAKER:mode=="mic"?RCTL_TALK_VIRTUAL_MIC:mode=="both"?RCTL_TALK_BOTH:-1;
            if(!rctl_webrtc_guest_talk_route(owner,route))throw std::runtime_error("talk_route_denied");
            return strdup("{\"ok\":true}");
        }
        if(op=="device.diagnostics") {
            std::unique_ptr<char,decltype(&free)> raw(rctl_diagnostics_json(),free);
            auto all=GuestJSON::parse(raw.get());GuestJSON categories=GuestJSON::array();
            for(auto &category:all["categories"]) {
                auto title=category.value("title",std::string());
                if(title=="Jailbreak"||title=="Performance"||title=="Storage")categories.push_back(category);
            }
            return strdup(GuestJSON{{"categories",categories}}.dump().c_str());
        }
        if(op=="system.inventory") {
            auto kind=guest_text(args,"kind",16);
            if(kind=="packages"||kind=="tweaks") {
                char *raw=kind=="packages"?rctl_packages_json():rctl_tweaks_json();if(!raw)throw std::runtime_error("inventory_unavailable");
                auto value=GuestJSON::parse(raw);free(raw);auto all=value[kind];auto cursor=args.value("cursor",0);
                if(cursor<0||cursor>1000000)throw std::runtime_error("invalid_cursor");
                GuestJSON items=GuestJSON::array();for(size_t i=cursor;i<all.size()&&items.size()<40;i++) {
                    auto item=all[i];if(kind=="tweaks"&&item.contains("path")) {
                        auto path=item["path"].get<std::string>();auto name=path.substr(path.find_last_of('/')+1);
                        auto suffix=name.find(".dylib");if(suffix!=std::string::npos)item["tweak_name"]=name.substr(0,suffix);
                    }items.push_back(item);
                }
                return strdup(GuestJSON{{"items",items},{"total",all.size()},{"next",cursor+items.size()<all.size()?GuestJSON(cursor+items.size()):GuestJSON(nullptr)}}.dump().c_str());
            }
            throw std::runtime_error("invalid_inventory");
        }
        if(op=="media.browse") {
            int cursor=args.value("cursor",0);if(cursor<0||cursor>1000000)throw std::runtime_error("invalid_cursor");
            std::string kind=args.value("type",std::string("all"));if(kind!="all"&&kind!="photo"&&kind!="video")throw std::runtime_error("invalid_media_type");
            auto query="type="+kind+"&limit=40&cursor="+std::to_string(cursor);
            return rctl_media_handle("/v1/media",query.c_str(),nullptr,0,status,length,contentType);
        }
        if(op=="media.preview"||op=="media.original") {
            auto id=guest_text(args,"id",128);std::string rendition=op=="media.original"?"original":args.value("rendition",std::string("preview"));
            if(rendition!="original"&&rendition!="preview"&&rendition!="thumb"&&rendition!="motion")throw std::runtime_error("invalid_rendition");
            if(op=="media.preview"&&(rendition=="original"||rendition=="motion"))throw std::runtime_error("original_download_permission_required");
            int fd=rctl_media_guest_open(id.c_str(),rendition.c_str());if(fd<0)throw std::runtime_error("asset_unavailable");
            std::unique_ptr<char,decltype(&free)> originalName(rctl_media_guest_name(id.c_str()),free);
            return strdup(GuestJSON{{"_guest_fd",fd},{"name",rendition=="preview"||rendition=="thumb"?"preview.jpg":originalName?originalName.get():"original"}}.dump().c_str());
        }
        if(op=="media.delete") {
            auto id=guest_text(args,"id",128);char *uuid=rctl_media_guest_uuid(id.c_str());if(!uuid)throw std::runtime_error("asset_not_deletable");
            auto params=GuestJSON{{"uuid",uuid}};free(uuid);char *result=guest_sb(owner,deadline,operation,params,status);
            rctl_media_guest_invalidate();return result;
        }
        if(op=="camera.snapshot") {
            std::lock_guard<std::mutex> captureLock(stillCaptureMutex);
            guest_current(owner,deadline);
            {std::lock_guard<std::mutex> lock(guestStillMutex);if(guestStill && guestStill->handed && !guestStill->stopped)throw std::runtime_error("camera_cleanup_pending");}
            if(rctl_camera_is_enabled())throw std::runtime_error("stop_live_camera_first");
            auto position=guest_text(args,"position",8);if(position!="back"&&position!="front")throw std::runtime_error("invalid_camera_position");
            auto state=std::make_shared<GuestStill>();state->owner=owner;state->deadline=std::min(deadline,guest_clock()+4.0);state->position=position=="front"?2:1;
            unsigned char bytes[32];arc4random_buf(bytes,sizeof bytes);char token[65];for(unsigned i=0;i<32;i++)snprintf(token+2*i,3,"%02x",bytes[i]);state->token=token;
            {std::lock_guard<std::mutex> lock(guestStillMutex);guestStill=state;}
            send_media_state(false,true);
            notify_post(position=="front"?"com.greatlove.rctl.cam.guest.front":"com.greatlove.rctl.cam.guest.back");
            NSData *jpeg=nil;
            while(guest_clock()<state->deadline) {
                {std::lock_guard<std::mutex> lock(guestStillMutex);jpeg=state->jpeg;if(jpeg||state->ended)break;}
                usleep(20000);
            }
            {std::lock_guard<std::mutex> lock(guestStillMutex);state->ended=true;state->jpeg=nil;}
            notify_post("com.greatlove.rctl.cam.guest.cancel");
            dispatch_async(gAuto,^{apply_active();});
            if(!jpeg.length)throw std::runtime_error("foreground_camera_unavailable");
            *length=jpeg.length;*contentType="image/jpeg";char *output=(char*)malloc(jpeg.length);memcpy(output,jpeg.bytes,jpeg.length);return output;
        }
        if(op=="screen.snapshot") {
            // Serialize the existing SpringBoard capture pathname until the
            // dispatcher has copied bytes into its anonymous owned descriptor.
            std::lock_guard<std::mutex> lock(screenSnapshotMutex);
            char *reply=guest_sb(owner,deadline,operation,args,status);
            bool ok=reply&&strstr(reply,"\"ok\":true");free(reply);if(!ok)throw std::runtime_error("capture_failed");
            int fd=open("/tmp/rctl-shot.png",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);unlink("/tmp/rctl-shot.png");
            struct stat st={};if(fd<0||fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>(64<<20)){if(fd>=0)close(fd);throw std::runtime_error("capture_failed");}
            return strdup(GuestJSON{{"_guest_fd",fd},{"name","capture.png"}}.dump().c_str());
        }
        // Global capture primitives are exclusively reserved; a guest cannot
        // stop another session's resource or inherit its pre-existing recording.
        if(op=="audio.playback"||op=="audio.microphone"||op=="audio.record"||op=="camera.live"||op=="camera.record") {
            const bool on=guest_bool(args,"on");
            std::string resource=op=="audio.playback"?"playback":op=="audio.microphone"?"microphone":op=="audio.record"?"mic-record":op=="camera.live"?"camera":"camera-record";
            std::lock_guard<std::mutex> lock(guestResourcesMutex);
            guest_current(owner,deadline);
            auto it=guestResources.find(resource);
            if(it!=guestResources.end()&&it->second!=owner)throw std::runtime_error("resource_in_use");
            if(on&&it==guestResources.end()) {
                if((resource=="playback"&&gAudioCaptureDesired)||(resource=="microphone"&&g_micListenWant)||(resource=="mic-record"&&(g_micRecordWant||file_exists(RCTL_MIC_REC_PATH)))||(resource=="camera-record"&&file_exists(RCTL_CAMERA_RECORD_PATH))||(resource=="camera"&&rctl_camera_is_enabled()))throw std::runtime_error("owner_resource_in_use");
                guestResources[resource]=owner;
            }
            if(!on&&it==guestResources.end())return strdup("{\"ok\":true}");
            try {
            if(resource=="playback") {char error[128]={};if(!audio_capture_set(on,error,sizeof error,owner,deadline))throw std::runtime_error("capture_failed");}
            if(resource=="microphone"){g_micListenWant=on;rctl_mic_refresh();if(on&&!g_micCapturing)throw std::runtime_error("microphone_unavailable");}
            if(resource=="mic-record") {
                if(on){unlink(RCTL_MIC_REC_PATH);g_micRecordWant=true;rctl_mic_refresh();if(!g_micCapturing || !rctl_mic_record_start())throw std::runtime_error("microphone_unavailable");}
                else {rctl_mic_record_stop();g_micRecordWant=false;rctl_mic_refresh();}
            }
            if(resource=="camera") {
                auto position=args.value("position",std::string("back"));if(position!="back"&&position!="front")throw std::runtime_error("invalid_camera_position");
                __block uint64_t generation=0;
                __block bool denied=false;
                dispatch_sync(gAuto,^{if(on && (guest_clock()>=deadline || !rctl_webrtc_guest_operations_current(owner))){denied=true;return;}gCameraLive=on;apply_active();generation=rctl_camera_set_enabled(on,position=="front"?2:1,10,1500000);});
                if(denied)throw std::runtime_error("access_ended");
                if(on)guestCameraGenerations[owner].insert(generation);
            }
            if(resource=="camera-record") {
                if(on){auto camera=guestResources.find("camera");if(camera==guestResources.end()||camera->second!=owner||!rctl_camera_record_start())throw std::runtime_error("start_owned_camera_first");}
                else rctl_camera_record_stop();
            }
            if(resource=="mic-record"||resource=="camera-record") {if(on)guestRecordingDeadlines[resource]=guest_clock()+300;else guestRecordingDeadlines.erase(resource);}
            } catch(...) {
                if(resource=="microphone"){g_micListenWant=false;rctl_mic_refresh();guestResources.erase(resource);}
                if(resource=="mic-record"){rctl_mic_record_stop();g_micRecordWant=false;rctl_mic_refresh();guestRecordingDeadlines.erase(resource);}
                if(resource=="playback"){audio_capture_set(false,nullptr,0);guestResources.erase(resource);}
                throw;
            }
            // Retain reservation for captures until explicit discard or session
            // end, so a later guest cannot read another person's artifact.
            if(!on&&resource!="mic-record"&&resource!="camera-record"&&resource!="camera")guestResources.erase(resource);
            return strdup("{\"ok\":true}");
        }
        *status=501;return strdup("{\"error\":\"operation_unavailable\"}");
    } catch(const std::exception &error) {*status=400;return strdup(GuestJSON{{"error",error.what()}}.dump().c_str());}
}

static void guest_recording_limits_init() {
    static dispatch_source_t timer;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
    dispatch_source_set_event_handler(timer,^{
        std::lock_guard<std::mutex> lock(guestResourcesMutex);
        for(auto it=guestRecordingDeadlines.begin();it!=guestRecordingDeadlines.end();) {
            const bool mic=it->first=="mic-record";struct stat st={};struct statfs disk={};
            stat(mic?RCTL_MIC_REC_PATH:RCTL_CAMERA_RECORD_PATH,&st);statfs("/var/mobile",&disk);
            if(guest_clock()<it->second && st.st_size<(256<<20) && (uint64_t)disk.f_bavail*disk.f_bsize>(64ULL<<20)){++it;continue;}
            if(mic){rctl_mic_record_stop();g_micRecordWant=false;rctl_mic_refresh();}else rctl_camera_record_stop();
            it=guestRecordingDeadlines.erase(it);
        }
    });dispatch_resume(timer);
}
}
