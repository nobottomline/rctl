#import <Foundation/Foundation.h>
#include "net/GuestOperations.h"
static bool accessCurrent=true;
extern "C" bool rctl_webrtc_guest_operations_current(const char *) {return accessCurrent;}
void rctl_webrtc_set_guest_operations(rctl_guest_request, bool (*)(const char *), void (*)(const char *,double)) {}
#include "../core/net/GuestDispatcher.mm"
#include <cassert>
#include <filesystem>
#include <fstream>
static void denied(Context &context, const std::string &operation, json arguments) {
    bool rejected=false;try {run(context,operation,arguments);}catch (...) {rejected=true;}assert(rejected);
}
static json response(const char *owner, const std::string &body) {
    struct Reply {
        std::mutex mutex;
        std::condition_variable ready;
        std::string value;
    } reply;
    request(owner, now()+20, "[\"files.list\"]", body.data(), body.size(),
        [](void *raw, const char *value) {
            auto &reply=*static_cast<Reply *>(raw);
            std::lock_guard<std::mutex> lock(reply.mutex);
            reply.value=value;reply.ready.notify_one();
        }, &reply);
    std::unique_lock<std::mutex> lock(reply.mutex);
    assert(reply.ready.wait_for(lock, std::chrono::seconds(5), [&] {return !reply.value.empty();}));
    return json::parse(reply.value);
}
int main() {
    @autoreleasepool {
        char directory[]="/tmp/rctl-guest-dispatcher.XXXXXX";assert(mkdtemp(directory));
        auto root=std::filesystem::path(directory);
        std::ofstream(root/"existing.txt")<<"owner";
        Context context;context.owner="test-owner";context.deadline=now()+20;
        context.exchange=std::make_unique<rctl::GuestFiles>(open(directory,O_RDONLY|O_DIRECTORY));
        context.rights={"files.list","files.preview","files.upload"};
        Context forbidden;forbidden.owner="forbidden";forbidden.deadline=now()+20;
        for(const std::string &operation:{"input.pointer","input.text","device.info","device.diagnostics","device.brightness","device.orientation","clipboard.read","clipboard.write","apps.list","apps.launch","apps.open_url","screen.snapshot","audio.playback","audio.microphone","audio.record","audio.output","capture.download","camera.live","camera.snapshot","camera.record","media.browse","media.preview","media.original","media.delete","files.list","files.open","files.preview","files.upload.begin","files.upload.chunk","files.upload.commit","files.delete","system.inventory","system.package_download","system.tweak_toggle","system.package_remove","system.respring","terminal.open","terminal.read","terminal.write","terminal.resize","terminal.close"}) {
            bool permissionDenied=false;
            try{run(forbidden,operation,json::object());}catch(const std::exception &error){permissionDenied=std::string(error.what())=="permission_denied";}
            assert(permissionDenied);
        }
        denied(context,"files.open",{{"path","existing.txt"}});
        denied(context,"files.delete",{{"path","existing.txt"}});
        denied(context,"terminal.open",json::object());
        denied(context,"capture.status",json::object());
        auto preview=run(context,"files.preview",{{"path","existing.txt"}});
        auto bytes=run(context,"transfer.read",{{"transfer",preview["transfer"]},{"offset",0}});
        assert(bytes["data"]=="b3duZXI=");
        Context stranger;stranger.deadline=now()+20;stranger.rights={"files.preview"};
        denied(stranger,"transfer.read",{{"transfer",preview["transfer"]},{"offset",0}});
        run(context,"files.upload.begin",{{"path","new.txt"},{"size",4}});
        denied(context,"files.upload.chunk",{{"offset",1},{"data","dGVzdA=="}});
        run(context,"files.upload.chunk",{{"offset",0},{"data","dGVzdA=="}});
        run(context,"files.upload.commit",json::object());
        assert(std::filesystem::exists(root/"new.txt"));
        run(context,"files.upload.begin",{{"path","existing.txt"},{"size",4}});
        run(context,"files.upload.chunk",{{"offset",0},{"data","dGVzdA=="}});
        denied(context,"files.upload.commit",json::object());
        context.abortUpload();
        denied(context,"files.upload.begin",{{"path","existing.txt"},{"size",4},{"overwrite",true}});
        context.rights.insert("files.overwrite");
        run(context,"files.upload.begin",{{"path","existing.txt"},{"size",4},{"overwrite",true}});
        run(context,"files.upload.chunk",{{"offset",0},{"data","dGVzdA=="}});
        run(context,"files.upload.commit",json::object());
        std::ifstream existing(root/"existing.txt");std::string value;existing>>value;assert(value=="test");
        run(context,"files.upload.begin",{{"path","partial.txt"},{"size",40}});
        auto temporary=context.uploadTemp;assert(std::filesystem::exists(root/temporary));
        context.rights.insert("files.delete");
        auto confirmation=run(context,"confirmation.issue",{{"operation","files.delete"},{"args",{{"path","new.txt"}}}});
        denied(stranger,"files.delete",{{"path","new.txt"},{"token",confirmation["token"]}});
        denied(context,"files.delete",{{"path","existing.txt"},{"token",confirmation["token"]}});
        run(context,"files.delete",{{"path","new.txt"},{"token",confirmation["token"]}});
        assert(!std::filesystem::exists(root/"new.txt"));
        denied(context,"files.delete",{{"path","new.txt"},{"token",confirmation["token"]}});
        accessCurrent=false;
        denied(context,"files.upload.commit",json::object());
        accessCurrent=true;
        context.ended=true;
        denied(context,"files.upload.commit",json::object());
        context.abortUpload();assert(!std::filesystem::exists(root/temporary));
        assert(!std::filesystem::exists(root/"partial.txt"));
        auto metadata=sanitize({{"name","private name"},{"udid","private"},{"serial","private"},{"imei","private"},{"items",json::array({{{"id","asset"},{"path","/private"},{"motion_path","/private"}}})}});
        assert(!metadata.contains("name")&&!metadata.contains("udid")&&!metadata.contains("serial")&&!metadata.contains("imei"));
        assert(!metadata["items"][0].contains("path"));
        static int exported=-1;
        exported=::open((root/"existing.txt").c_str(),O_RDONLY);
        deviceAction=+[](const char*,double,const char*,const char*,int*,int*,const char**)->char* {
            accessCurrent=false;
            return strdup(json{{"_guest_fd",exported},{"name","test"}}.dump().c_str());
        };
        Context capture;capture.owner="capture";capture.deadline=now()+20;capture.rights={"screen.snapshot"};
        accessCurrent=true;denied(capture,"screen.snapshot",json::object());
        assert(fcntl(exported,F_GETFD)==-1&&errno==EBADF);
        accessCurrent=true;
        deviceAction=+[](const char*,double,const char*,const char*,int*,int*,const char**)->char* {return strdup("{\"microphone\":true,\"camera\":true}");};
        Context recorder;recorder.owner="recorder";recorder.deadline=now()+20;recorder.rights={"audio.microphone.record"};
        auto recording=run(recorder,"capture.status",json::object());
        assert(recording["microphone"]==true&&!recording.contains("camera"));
        deviceAction=nullptr;
        // Native metadata that is not UTF-8 must not escape the reply boundary.
        auto unencodable=json{{"id",71},{"result",{{"name",std::string("invalid-\xff",9)}}}};
        bool strictEncodingFailed=false;
        try { (void)unencodable.dump(); } catch(const json::exception &) {strictEncodingFailed=true;}
        assert(strictEncodingFailed);
        auto failed=json::parse(serializeResponse(unencodable,71));
        assert(failed["id"]==71&&failed["error"]=="response_unavailable");
        assert(json::parse(serializeResponse({{"result",std::string(65536,'x')}},71))["error"]=="response_too_large");
        // Exercise the public asynchronous path, then a valid request to prove
        // a malformed payload cannot strand pending work or expose its bytes.
        auto malformed=std::make_shared<Context>();
        malformed->owner="malformed-file-owner";malformed->deadline=now()+20;
        malformed->rights={"files.list"};
        malformed->exchange=std::make_unique<rctl::GuestFiles>(open(directory,O_RDONLY|O_DIRECTORY));
        contexts[malformed->owner]=malformed;
        auto invalid=response(malformed->owner.c_str(), R"({"id":71,"op":"files.list","args":{"path":"private-fixture)");
        assert(invalid["error"]=="invalid_request");
        assert(malformed->pending==0);
        auto recovered=response(malformed->owner.c_str(), R"({"id":72,"op":"files.list","args":{}})");
        assert(recovered["id"]==72&&recovered["result"].contains("items"));
        assert(response(malformed->owner.c_str(), R"({"id":73,"op":"files.list","args":null})")["error"]=="invalid_request");
        assert(end(malformed->owner.c_str()));
        std::filesystem::remove_all(root);
    }
}
