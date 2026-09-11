#include "net/WebRTCPermissions.h"
#include "net/ControllerAuthorizationLease.h"

#include <cstdlib>
#include <iostream>

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

int main() {
    rctl::ControllerAuthorizationLease lease(1, 100);
    require(!lease.authorized(100), "unconfirmed lease grants no access");
    lease.challenge("nonce", 100);
    require(!lease.renew(2, "nonce", 101), "another revision cannot renew");
    require(lease.renew(1, "nonce", 115), "matching challenge renews");
    require(lease.expiresAt == 120, "delayed response cannot extend from arrival");
    require(!lease.renew(1, "nonce", 116), "challenge replay rejected");
    lease.challenge("next", 116);
    require(!lease.renew(1, "next", 120), "expired lease cannot be resurrected");
    require(!lease.authorized(120), "deadline comparison is exclusive");
    lease.retired = true;
    require(!lease.authorized(117), "retired owner grants no access");
    const auto legacy = rctl::legacyWebRTCPermissions();
    require(!legacy.scoped, "legacy session must remain unscoped");
    require(legacy.screenView && legacy.camera && legacy.audioListen &&
                legacy.deviceControl && legacy.filesRead &&
                legacy.filesWrite && legacy.microphoneTalk,
            "legacy local/admin sessions must preserve every existing channel");

    const auto viewOnly = rctl::scopedWebRTCPermissions({"screen.view"});
    require(viewOnly.scoped, "controller session must be marked scoped");
    require(viewOnly.screenView && !viewOnly.camera,
            "screen view and camera must remain independent");
    require(!viewOnly.audioListen && !viewOnly.deviceControl &&
                !viewOnly.filesRead && !viewOnly.filesWrite &&
                !viewOnly.microphoneTalk,
            "screen view must not imply a DataChannel permission");

    const auto readOnly = rctl::scopedWebRTCPermissions({"files.read"});
    require(rctl::webRTCFilesMessageAllowed(readOnly, false, "get"),
            "files.read must permit get");
    require(!rctl::webRTCFilesMessageAllowed(readOnly, false, "put"),
            "files.read must reject put");
    require(!rctl::webRTCFilesMessageAllowed(readOnly, true, ""),
            "files.read must reject upload chunks");

    const auto writeOnly = rctl::scopedWebRTCPermissions({"files.write"});
    require(!rctl::webRTCFilesMessageAllowed(writeOnly, false, "get"),
            "files.write must reject get");
    require(rctl::webRTCFilesMessageAllowed(writeOnly, false, "put"),
            "files.write must permit put");
    require(rctl::webRTCFilesMessageAllowed(writeOnly, false, "put_eof"),
            "files.write must permit put_eof");
    require(rctl::webRTCFilesMessageAllowed(writeOnly, true, ""),
            "files.write must permit upload chunks");
    require(!rctl::webRTCFilesMessageAllowed(writeOnly, false, "unknown"),
            "unknown file operations must fail closed");

    const auto controls = rctl::scopedWebRTCPermissions(
        {"audio.listen", "device.control", "microphone.talk", "unknown.future"});
    require(controls.audioListen && controls.deviceControl && controls.microphoneTalk,
            "known realtime scopes must map independently");
    require(!controls.filesRead && !controls.filesWrite,
            "unknown scopes must not grant file access");

    std::cout << "WebRTC permission tests passed\n";
    return 0;
}
