#import <Foundation/Foundation.h>
#import "net/GuestDispatcher.h"
#import "net/WebRTCBridge.h"
#import "platform/Paths.h"
#include "security/GuestFiles.h"
#include <nlohmann/json.hpp>
#include <mach/mach_time.h>
#include <util.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <signal.h>
#include <atomic>
#include <mutex>
#include <map>
#include <set>
#include <memory>
#include <condition_variable>
#include <chrono>
#include <thread>
#include <algorithm>
using json = nlohmann::json;
namespace {
constexpr size_t chunkBytes = 24576;
constexpr uint64_t uploadLimit = 512ULL << 20;
static rctl_guest_device_action deviceAction;
static double now() {
    static const mach_timebase_info_data_t base = [] { mach_timebase_info_data_t b; mach_timebase_info(&b); return b; }();
    return double(mach_continuous_time()) * base.numer / base.denom / 1e9;
}
struct FD { int fd=-1; ~FD() { if(fd>=0) close(fd); } explicit FD(int value=-1):fd(value) {} FD(const FD&)=delete; };
struct Context {
    std::string owner;
    std::set<std::string> rights;
    std::atomic<bool> ended{false};
    std::atomic<double> deadline{0};
    std::atomic<unsigned> pending{0};
    std::mutex gate;
    std::condition_variable drained;
    double lastRequest=0;
    unsigned requests=0;
    std::unique_ptr<rctl::GuestFiles> exchange;
    std::map<std::string,std::shared_ptr<FD>> reads;
    std::map<std::string,std::string> readPermission;
    std::shared_ptr<FD> uploadDir, upload;
    std::string uploadTemp, uploadName;
    uint64_t uploadSize=0, uploadWritten=0;
    bool overwrite=false;
    std::string confirmation, confirmationOperation, confirmationArguments;
    double confirmationDeadline=0;
    std::shared_ptr<FD> pty;
    pid_t child=-1;
    bool has(const char *p) const { return rights.count(p); }
    void require(const char *p) const { if(!has(p)) throw std::runtime_error("permission_denied"); }
    void current() const { if(ended || now() >= deadline.load() || !rctl_webrtc_guest_operations_current(owner.c_str())) throw std::runtime_error("access_ended"); }
    void abortUpload() {
        upload.reset();
        if(uploadDir && !uploadTemp.empty()) unlinkat(uploadDir->fd,uploadTemp.c_str(),0);
        uploadDir.reset(); uploadTemp.clear(); uploadName.clear(); uploadWritten=uploadSize=0;
    }
    void closeTerminal() {
        pid_t foreground=pty ? tcgetpgrp(pty->fd) : -1;
        if(foreground>0 && foreground!=getpgrp() && foreground!=child && getsid(foreground)==child) {
            kill(-foreground,SIGHUP);kill(-foreground,SIGKILL);
        }
        pty.reset();
        if(child>0) {
            // The PTY child creates its own session/process group. Never signal
            // an unrelated process by name or a reused, already-reaped PID.
            kill(-child,SIGHUP); kill(-child,SIGKILL); kill(child,SIGKILL);
            int status; while(waitpid(child,&status,0)<0 && errno==EINTR) {}
            child=-1;
        }
    }
    ~Context() { abortUpload(); closeTerminal(); }
};
std::mutex contextsMutex;
std::map<std::string,std::shared_ptr<Context>> contexts;
std::string text(const json &args, const char *key, size_t limit=1024, bool optional=false) {
    if(!args.contains(key)) { if(optional) return ""; throw std::runtime_error("missing_argument"); }
    if(!args[key].is_string()) throw std::runtime_error("invalid_argument");
    auto value=args[key].get<std::string>();
    if(value.size()>limit || value.find('\0')!=std::string::npos) throw std::runtime_error("invalid_argument");
    return value;
}
uint64_t integer(const json &args,const char *key,uint64_t maximum,uint64_t fallback=0) {
    if(!args.contains(key)) return fallback;
    if(!args[key].is_number_unsigned() && !args[key].is_number_integer()) throw std::runtime_error("invalid_argument");
    if(args[key].get<int64_t>()<0) throw std::runtime_error("invalid_argument");
    uint64_t v=args[key].get<uint64_t>(); if(v>maximum) throw std::runtime_error("invalid_argument"); return v;
}
std::string encode(const void *bytes,size_t length) {
    NSData *data=[NSData dataWithBytes:bytes length:length];
    return [[data base64EncodedStringWithOptions:0] UTF8String];
}
NSData *decode(const std::string &value) {
    if(value.size()>32768) throw std::runtime_error("chunk_too_large");
    NSData *data=[[NSData alloc] initWithBase64EncodedString:@(value.c_str()) options:0];
    if(!data || data.length>chunkBytes) throw std::runtime_error("invalid_chunk"); return data;
}
std::string resourceID() { return [NSUUID UUID].UUIDString.UTF8String; }
// Remove owner-only paths/identities from all nested metadata, not only tiles.
json sanitize(json value) {
    if(value.is_object()) {
        const bool deviceIdentity=value.contains("udid");
        for(auto it=value.begin();it!=value.end();) {
            const auto &key=it.key();
            if(key=="path" || key=="motion_path" || key=="uuid" || key=="udid" || key=="imei" || (key=="name" && deviceIdentity) || key=="serial" || key=="device_id" || key=="relay_url") it=value.erase(it);
            else { it.value()=sanitize(it.value()); ++it; }
        }
    } else if(value.is_array()) for(auto &v:value) v=sanitize(v);
    return value;
}
const char *permission(const std::string &op) {
    static const std::map<std::string,const char *> operations={
        {"input.pointer","input.pointer"},{"input.text","input.text"},{"device.info","device.info"},{"device.diagnostics","device.diagnostics"},
        {"device.brightness","device.brightness"},{"device.orientation","device.orientation"},
        {"clipboard.read","clipboard.read"},{"clipboard.write","clipboard.write"},
        {"apps.list","apps.list"},{"apps.launch","apps.launch"},{"apps.open_url","apps.open_url"},
        {"screen.snapshot","screen.snapshot"},{"audio.playback","audio.playback.listen"},
        {"audio.microphone","audio.microphone.listen"},{"audio.record","audio.microphone.record"},
        {"audio.output","audio.output"},{"talk.route","talk.speaker"},
        {"capture.download","capture.download"},{"camera.live","camera.live"},{"camera.snapshot","camera.snapshot"},{"camera.record","camera.record"},
        {"media.browse","media.browse"},{"media.preview","media.preview"},{"media.original","media.download"},
        {"media.delete","media.delete"},{"files.list","files.list"},{"files.open","files.download"},
        {"files.preview","files.preview"},{"files.upload.begin","files.upload"},{"files.upload.chunk","files.upload"},
        {"files.upload.commit","files.upload"},{"files.delete","files.delete"},
        {"system.inventory","system.inventory"},{"system.package_download","system.package_download"},
        {"system.tweak_toggle","system.tweak_toggle"},{"system.package_remove","system.package_remove"},{"system.respring","system.respring"},
        {"terminal.open","terminal.root"},{"terminal.read","terminal.root"},{"terminal.write","terminal.root"},
        {"terminal.resize","terminal.root"},{"terminal.close","terminal.root"},
    };
    auto it=operations.find(op); return it==operations.end()?nullptr:it->second;
}
json readMetadata(Context &context,std::shared_ptr<FD> file,const char *right,const std::string &name) {
    struct stat st={};
    if(!file || file->fd<0 || fstat(file->fd,&st) || !S_ISREG(st.st_mode) || st.st_size<0) throw std::runtime_error("file_unavailable");
    if(context.reads.size()>=4) throw std::runtime_error("transfer_limit");
    auto id=resourceID(); context.reads[id]=file; context.readPermission[id]=right;
    return {{"transfer",id},{"size",st.st_size},{"name",name}};
}
json run(Context &context,const std::string &op,const json &args) {
    context.current();
    if(op=="capture.status") {
        if(!context.has("audio.microphone.record")&&!context.has("camera.record"))throw std::runtime_error("permission_denied");
        if(!deviceAction)throw std::runtime_error("operation_unavailable");
        int status=200,length=0;const char *type=nullptr;
        std::unique_ptr<char,decltype(&free)> raw(deviceAction(context.owner.c_str(),context.deadline,op.c_str(),"{}",&status,&length,&type),free);
        if(status>=400||!raw)throw std::runtime_error("recording_status_unavailable");
        context.current();auto result=json::parse(raw.get());
        if(!context.has("audio.microphone.record"))result.erase("microphone");
        if(!context.has("camera.record"))result.erase("camera");
        return result;
    }
    if(op=="confirmation.issue") {
        auto operation=text(args,"operation",64);
        const char *right=permission(operation);
        if(!right || (operation!="media.delete"&&operation!="files.delete"&&operation!="system.tweak_toggle"&&operation!="system.package_remove"&&operation!="system.respring") || !args.contains("args") || !args["args"].is_object()) throw std::runtime_error("invalid_confirmation");
        context.require(right);context.confirmation=resourceID();context.confirmationOperation=operation;
        context.confirmationArguments=args["args"].dump();context.confirmationDeadline=now()+30;
        return {{"token",context.confirmation},{"expires_in",30}};
    }
    if(op=="transfer.close") {
        auto id=text(args,"transfer",64); context.reads.erase(id);context.readPermission.erase(id);return {{"ok",true}};
    }
    if(op=="transfer.read") {
        auto id=text(args,"transfer",64);
        auto it=context.reads.find(id); if(it==context.reads.end()) throw std::runtime_error("transfer_not_found");
        context.require(context.readPermission.at(id).c_str());
        uint64_t offset=integer(args,"offset",INT64_MAX);
        char buffer[chunkBytes]; ssize_t size=pread(it->second->fd,buffer,sizeof buffer,(off_t)offset);
        if(size<0) throw std::runtime_error("read_failed");
        return {{"data",encode(buffer,size)},{"offset",offset},{"eof",size==0}};
    }
    if(op=="files.upload.cancel") { context.abortUpload(); return {{"ok",true}}; }
    const char *right=permission(op);if(!right) throw std::runtime_error("unknown_operation");
    if(op=="talk.route") {
        auto mode=text(args,"mode",8);
        if(mode!="speaker" && mode!="mic" && mode!="both") throw std::runtime_error("invalid_route");
        if(mode!="mic") context.require("talk.speaker");
        if(mode!="speaker") context.require("talk.virtual_microphone");
    } else context.require(right);
    json effectiveArgs=args;
    if(op=="media.delete"||op=="files.delete"||op=="system.tweak_toggle"||op=="system.package_remove"||op=="system.respring") {
        auto token=text(args,"token",64);effectiveArgs.erase("token");
        if(token!=context.confirmation||op!=context.confirmationOperation||effectiveArgs.dump()!=context.confirmationArguments||now()>=context.confirmationDeadline)throw std::runtime_error("invalid_or_expired_confirmation");
        context.confirmation.clear();context.confirmationArguments.clear();
    }
    if(op.rfind("files.",0)==0) {
        if(!context.exchange) {
            // Walk even the fixed parent path without following a replaceable
            // symlink; no sibling runtime/configuration directory is admitted.
            auto directory=std::make_shared<FD>(open("/var/mobile",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
            for(const char *component:{"Library","Caches","com.greatlove.rctl","exchange"}) {
                if(directory->fd<0 || (mkdirat(directory->fd,component,0700) && errno!=EEXIST))throw std::runtime_error("exchange_unavailable");
                directory=std::make_shared<FD>(openat(directory->fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
            }
            struct stat st={};
            if(directory->fd<0 || fstat(directory->fd,&st) || st.st_uid!=0 || (st.st_mode&0077))throw std::runtime_error("exchange_unavailable");
            context.exchange=std::make_unique<rctl::GuestFiles>(directory->fd);directory->fd=-1;
        }
        if(op=="files.list") {
            FD fd(context.exchange->open(text(args,"path",1024,true),true));
            DIR *dir=fdopendir(dup(fd.fd));if(!dir) throw std::runtime_error("directory_unavailable");
            json items=json::array();
            while(auto *entry=readdir(dir)) {
                if(entry->d_name[0]=='.') continue;
                struct stat st={};
                if(fstatat(fd.fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW) || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) || (S_ISREG(st.st_mode)&&st.st_nlink!=1))continue;
                if(items.size()>=500) {closedir(dir);throw std::runtime_error("directory_too_large");}
                items.push_back({{"name",entry->d_name},{"directory",bool(S_ISDIR(st.st_mode))},{"size",st.st_size}});
            }
            closedir(dir); return {{"items",items}};
        }
        if(op=="files.open" || op=="files.preview") {
            auto path=text(args,"path");auto file=std::make_shared<FD>(context.exchange->open(path));
            if(op=="files.preview") {struct stat st={};fstat(file->fd,&st);if(st.st_size>2*1024*1024) throw std::runtime_error("preview_too_large");}
            return readMetadata(context,file,right,path.substr(path.find_last_of('/')+1));
        }
        if(op=="files.delete") {context.exchange->remove(text(args,"path"));return {{"ok",true}};}
        if(op=="files.upload.begin") {
            context.abortUpload();
            context.uploadSize=integer(args,"size",uploadLimit);
            std::string name;auto dir=std::make_shared<FD>(context.exchange->parent(text(args,"path"),name));
            struct statfs disk={};
            if(fstatfs(dir->fd,&disk) || (uint64_t)disk.f_bavail*disk.f_bsize<context.uploadSize+(64ULL<<20))throw std::runtime_error("insufficient_exchange_space");
            context.overwrite=args.value("overwrite",false);
            if(context.overwrite) context.require("files.overwrite");
            context.uploadName=name; context.uploadTemp=".rctl-"+resourceID();context.uploadDir=dir;
            context.upload=std::make_shared<FD>(openat(dir->fd,context.uploadTemp.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
            if(context.upload->fd<0) {context.abortUpload();throw std::runtime_error("upload_failed");}
            return {{"ok",true},{"chunk_bytes",chunkBytes}};
        }
        if(op=="files.upload.chunk") {
            if(!context.upload) throw std::runtime_error("upload_not_started");
            struct statfs disk={};
            if(fstatfs(context.upload->fd,&disk) || (uint64_t)disk.f_bavail*disk.f_bsize<(64ULL<<20)){context.abortUpload();throw std::runtime_error("insufficient_exchange_space");}
            if(integer(args,"offset",uploadLimit)!=context.uploadWritten) throw std::runtime_error("invalid_offset");
            NSData *data=decode(text(args,"data",32768));
            if(context.uploadWritten+data.length>context.uploadSize) throw std::runtime_error("upload_size_exceeded");
            if(write(context.upload->fd,data.bytes,data.length)!=(ssize_t)data.length) {context.abortUpload();throw std::runtime_error("upload_write_failed");}
            context.uploadWritten+=data.length;return {{"written",context.uploadWritten}};
        }
        if(op=="files.upload.commit") {
            if(!context.upload || context.uploadWritten!=context.uploadSize) throw std::runtime_error("incomplete_upload");
            context.current(); if(fsync(context.upload->fd)) throw std::runtime_error("upload_sync_failed");
            context.current();
            auto dir=context.uploadDir;
            int result;
            if(context.overwrite) {
                context.require("files.overwrite");struct stat st={};
                if(!fstatat(dir->fd,context.uploadName.c_str(),&st,AT_SYMLINK_NOFOLLOW) && (!S_ISREG(st.st_mode)||st.st_nlink!=1))throw std::runtime_error("overwrite_denied");
                result=renameat(dir->fd,context.uploadTemp.c_str(),dir->fd,context.uploadName.c_str());
            } else {
                // linkat is an atomic no-replace commit; a racing existing target
                // cannot turn upload authority into overwrite authority.
                result=linkat(dir->fd,context.uploadTemp.c_str(),dir->fd,context.uploadName.c_str(),0);
                if(!result) unlinkat(dir->fd,context.uploadTemp.c_str(),0);
            }
            if(result) throw std::runtime_error("target_exists_or_commit_failed");
            fsync(dir->fd);context.abortUpload();return {{"ok",true}};
        }
    }
    if(op.rfind("terminal.",0)==0) {
        if(op=="terminal.close") {context.closeTerminal();return {{"ok",true}};}
        if(op=="terminal.open") {
            if(context.pty) throw std::runtime_error("terminal_already_open");
            auto cols=integer(args,"cols",500,100),rows=integer(args,"rows",200,30);
            if(cols<20||rows<5)throw std::runtime_error("invalid_dimensions");
            struct winsize size={};size.ws_col=cols;size.ws_row=rows;int fd=-1;
            const char *shell=RCTL_ROOT_PATH("/bin/sh");
            if(access(shell,X_OK))throw std::runtime_error("shell_unavailable");
            std::vector<std::string> environment={"TERM=xterm-256color","HOME=/var/root","USER=root","LOGNAME=root",std::string("SHELL=")+shell,"PS1=${PWD} # ",std::string("PATH=")+RCTL_ROOT_PATH("/usr/bin")+":"+RCTL_ROOT_PATH("/usr/sbin")+":"+RCTL_ROOT_PATH("/bin")+":"+RCTL_ROOT_PATH("/sbin")+":/usr/bin:/bin:/usr/sbin:/sbin","LANG=C"};
            std::vector<char*> envp;for(auto &entry:environment)envp.push_back(entry.data());envp.push_back(nullptr);
            char *arguments[]={(char*)"sh",(char*)"-i",nullptr};
            char **childEnv=envp.data();int maxFD=getdtablesize();
            context.current();pid_t pid=forkpty(&fd,nullptr,nullptr,&size);
            if(pid<0)throw std::runtime_error("terminal_failed");
            if(!pid) {
                // No relay socket, file grant or private runtime FD reaches root sh.
                // Only async-signal-safe calls after fork in this multithreaded
                // daemon. Allocate environment/arguments in the parent.
                for(int i=3;i<maxFD;i++)close(i);
                chdir("/var/root");execve(shell,arguments,childEnv);_exit(127);
            }
            context.child=pid;context.pty=std::make_shared<FD>(fd);fcntl(fd,F_SETFL,O_NONBLOCK);fcntl(fd,F_SETFD,FD_CLOEXEC);
            return {{"ok",true}};
        }
        if(!context.pty) throw std::runtime_error("terminal_not_open");
        if(op=="terminal.read") {
            char buffer[chunkBytes];ssize_t count=read(context.pty->fd,buffer,sizeof buffer);
            if(count<0 && errno!=EAGAIN && errno!=EINTR) throw std::runtime_error("terminal_closed");
            return {{"data",encode(buffer,std::max<ssize_t>(0,count))},{"eof",count==0}};
        }
        if(op=="terminal.write") {
            NSData *data=decode(text(args,"data",32768));
            ssize_t count=write(context.pty->fd,data.bytes,data.length);
            if(count<0 && errno!=EAGAIN && errno!=EINTR)throw std::runtime_error("terminal_write_failed");
            return {{"written",std::max<ssize_t>(0,count)}};
        }
        if(op=="terminal.resize") {
            struct winsize size={};size.ws_col=integer(args,"cols",500);size.ws_row=integer(args,"rows",200);
            if(size.ws_col<20||size.ws_row<5||ioctl(context.pty->fd,TIOCSWINSZ,&size))throw std::runtime_error("resize_failed");
            return {{"ok",true}};
        }
    }
    if(!deviceAction) throw std::runtime_error("operation_unavailable");
    int status=200,length=0;const char *contentType="application/json";
    std::unique_ptr<char,decltype(&free)> output(deviceAction(context.owner.c_str(),context.deadline,op.c_str(),effectiveArgs.dump().c_str(),&status,&length,&contentType),free);
    if(!output) throw std::runtime_error("operation_failed");
    if(length==0 && contentType && std::string(contentType)=="application/json") {
        auto result=json::parse(output.get());
        if(status>=400 || result.contains("error") || (result.contains("ok") && result["ok"].is_boolean() && !result["ok"].get<bool>())) throw std::runtime_error(result.value("error",std::string("operation_failed")));
        // The media adapter returns admitted FDs as bounded internal metadata;
        // browser-selected filesystem paths never enter it.
        if(result.contains("_guest_fd")) {
            auto file=std::make_shared<FD>(result["_guest_fd"].get<int>());
            context.current();
            return readMetadata(context,file,right,result.value("name",std::string("download")));
        }
        context.current();
        return sanitize(result);
    }
    context.current();
    if(status>=400||length<=0||length>(64<<20))throw std::runtime_error("capture_failed");
    // Anonymous unlinked descriptor: private bytes disappear when the last
    // owning transfer closes; no session shares /tmp capture export paths.
    char path[]="/tmp/rctl-guest-capture.XXXXXX";int fd=mkstemp(path);
    if(fd<0)throw std::runtime_error("capture_failed");unlink(path);fcntl(fd,F_SETFD,FD_CLOEXEC);
    auto file=std::make_shared<FD>(fd);
    if(write(fd,output.get(),length)!=length)throw std::runtime_error("capture_failed");
    // Snapshot/preview authority permits displaying its bounded rendition;
    // exporting it is a separate UI action (a viewer can always retain pixels).
    return readMetadata(context,file,right,contentType&&std::string(contentType)=="image/png"?"capture.png":"capture.jpg");
}
std::string serializeResponse(const json &result, uint64_t id) {
    try {
        auto value=result.dump();
        if(value.size()>65536)return json{{"id",id},{"error","response_too_large"}}.dump();
        return value;
    } catch(const json::exception &) {
        // Never let unencodable native metadata terminate the daemon or echo
        // raw exception payloads. The caller still releases pending work.
        return json{{"id",id},{"error","response_unavailable"}}.dump();
    }
}
void request(const char *owner,double deadline,const char *rights,const char *body,size_t length,rctl_guest_reply reply,void *raw) {
    std::shared_ptr<Context> context;
    try {
        if(!rctl_webrtc_guest_operations_current(owner))throw std::runtime_error("access_ended");
        std::lock_guard<std::mutex> lock(contextsMutex);
        auto &slot=contexts[owner];
        if(!slot) {
            if(contexts.size()>32) {contexts.erase(owner);throw std::runtime_error("session_limit");}
            slot=std::make_shared<Context>();slot->owner=owner;
            for(auto &right:json::parse(rights))slot->rights.insert(right.get<std::string>());
            slot->deadline=deadline;
        }
        context=slot;
    } catch (...) {reply(raw,"{\"error\":\"operation_unavailable\"}");return;}
    auto payload=std::make_shared<std::string>(body,length);
    if(context->pending.fetch_add(1)>=2) {context->pending.fetch_sub(1);reply(raw,"{\"error\":\"busy\"}");return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            json result; uint64_t id=0;
            {
                std::lock_guard<std::mutex> gate(context->gate);
                try {
                    context->current();auto message=json::parse(*payload);
                    id=integer(message,"id",9007199254740991ULL);
                    if(id==0||!message.contains("args")||!message["args"].is_object())throw std::runtime_error("invalid_request");
                    auto operation=text(message,"op",64);
                    if(now()-context->lastRequest>1){context->lastRequest=now();context->requests=0;}
                    if(++context->requests>100)throw std::runtime_error("rate_limited");
                    result={{"id",id},{"result",run(*context,operation,message["args"])}};
                } catch(const json::exception &) {result={{"id",id},{"error","invalid_request"}};}
                  catch(const std::exception &error) {result={{"id",id},{"error",error.what()}};}
            }
            context->pending.fetch_sub(1);context->drained.notify_all();
            auto value=serializeResponse(result,id);
            reply(raw,value.c_str());
        }
    });
}
bool end(const char *owner) {
    std::shared_ptr<Context> context;
    bool first=false;
    {std::lock_guard<std::mutex> lock(contextsMutex);auto it=contexts.find(owner);if(it==contexts.end())return true;context=it->second;first=!context->ended.exchange(true);}
    if(deviceAction){int status=200,length=0;const char *type=nullptr;free(deviceAction(owner,0,"session.cancel","{}",&status,&length,&type));}
    // Do not hold the bridge mutex while draining native work. A failed drain
    // stays pending and cannot produce a device retirement acknowledgement.
    auto until=std::chrono::steady_clock::now()+std::chrono::milliseconds(1500);
    while(first && context->pending && std::chrono::steady_clock::now()<until)std::this_thread::sleep_for(std::chrono::milliseconds(5));
    if(context->pending)return false;
    {
        std::lock_guard<std::mutex> gate(context->gate);
        context->abortUpload();context->closeTerminal();context->reads.clear();context->readPermission.clear();
        if(deviceAction){int status=200,length=0;const char *type=nullptr;free(deviceAction(owner,0,"session.end","{}",&status,&length,&type));if(status>=400)return false;}
    }
    {std::lock_guard<std::mutex> lock(contextsMutex);contexts.erase(owner);}return true;
}
void renew(const char *owner,double deadline) {
    std::lock_guard<std::mutex> lock(contextsMutex);
    auto it=contexts.find(owner);
    if(it!=contexts.end()&&!it->second->ended&&now()<it->second->deadline)it->second->deadline=deadline;
}
}
void rctl_guest_dispatcher_init(rctl_guest_device_action action) {
    deviceAction=action;rctl_webrtc_set_guest_operations(request,end,renew);
    static dispatch_source_t timer;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
    dispatch_source_set_event_handler(timer, ^{
        std::vector<std::string> expired;
        {std::lock_guard<std::mutex> lock(contextsMutex);for(auto &entry:contexts)if(entry.second->ended||now()>=entry.second->deadline)expired.push_back(entry.first);}
        for(auto &owner:expired)end(owner.c_str());
    });dispatch_resume(timer);
}
