#include "net/WebRTCPermissions.h"
#include "net/ControllerAuthorizationLease.h"
#include "net/GuestInputState.h"
#include <limits>

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
    rctl::WebRTCPermissions guest;
    require(rctl::guestWebRTCPermissions({"screen.view"}, guest), "guest view policy accepted");
    require(guest.guest && guest.scoped && guest.screenView && !guest.deviceControl && !guest.filesRead && !guest.audioListen,
            "guest view opens no privileged channels");
    require(rctl::guestWebRTCPermissions({"screen.view", "input.keyboard"}, guest) && guest.inputKeyboard && !guest.inputTouch && !guest.inputButtons,
            "guest input rights are independent");
    require(!rctl::guestWebRTCPermissions({"screen.view", "device.control"}, guest), "native controller scope cannot widen guest policy");
    require(!rctl::guestWebRTCPermissions({"screen.view", "terminal"}, guest), "unsupported rights fail closed");
    require(rctl::guestWebRTCPermissions({"input.touch"}, guest) && !guest.screenView, "data-only guest sessions do not require screen exposure");
    require(rctl::guestWebRTCPermissions({"audio.playback.listen"},guest) && guest.audioListen && !guest.roomMicListen && !guest.microphoneTalk && !guest.camera,"playback does not expose the room microphone, Talk or camera");
    require(rctl::guestWebRTCPermissions({"audio.microphone.listen"},guest) && guest.roomMicListen && !guest.audioListen && !guest.microphoneTalk,"room microphone does not expose playback or Talk");
    require(rctl::guestWebRTCPermissions({"talk.virtual_microphone"},guest) && guest.microphoneTalk && !guest.roomMicListen && !guest.audioListen,"Talk does not permit listening");
    require(rctl::guestWebRTCPermissions({"input.text"},guest) && guest.inputText && !guest.inputKeyboard && !guest.inputTouch,"typed text does not authorize raw HID input");
    rctl::ControllerAuthorizationLease shortLease(2, 200);
    shortLease.challenge("expiry", 200);
    require(shortLease.renew(2, "expiry", 201, 2), "grant deadline shortens device lease");
    require(!shortLease.authorized(202), "hard expiry does not buy a full twenty seconds");
    rctl::ControllerAuthorizationLease delayed(2, 200);
    delayed.challenge("expired", 200);
    require(!delayed.renew(2, "expired", 203, 2), "delayed reply cannot pass the absolute grant budget");
    require(rctl::guestWebRTCPermissions({"screen.view", "input.button.home"}, guest) && guest.inputButtons && guest.buttonMask == rctl::GuestInputState::homeButton,
            "button grant selects only its named command");
    rctl::GuestInputState buttons;
    require(buttons.key(12, 0x40, 2, false, true, guest.buttonMask), "Home grant can press Home");
    require(!buttons.key(12, 0x30, 2, false, true, guest.buttonMask), "Home grant cannot lock the device");
    require(!buttons.key(12, 0xe9, 2, false, true, guest.buttonMask), "Home grant cannot change volume");
    require(!buttons.key(0xf0, 1, 2, false, true, guest.buttonMask), "Home grant cannot open Control Center");
    rctl::GuestInputState budget;
    for (int i=0; i<48; ++i) require(budget.admit(100), "bounded initial burst accepted");
    require(!budget.admit(100), "input flood cannot build an unbounded queue");
    require(budget.admit(101), "input budget recovers over time");
    rctl::GuestInputState input;
    require(!input.touch(1, 0, .5, .5), "unowned move rejected");
    require(!input.touch(0, 0, std::numeric_limits<double>::quiet_NaN(), .5), "non-finite coordinate rejected");
    require(!input.touch(0, 11, .5, .5), "out-of-range contact rejected");
    require(input.touch(0, 0, .1, .2) && input.touch(1, 0, .3, .4), "held contact tracked");
    require(!input.key(0xf1, 500, 1, true, true), "brightness sentinel not a device-button grant");
    require(!input.key(12, 0x40, 1, true, false), "keyboard grant cannot send Home");
    require(!input.key(7, 0x66, 2, true, false), "keyboard Power cannot bypass Lock policy");
    require(!input.key(7, 0x80, 2, true, false), "keyboard Volume Up cannot bypass Volume policy");
    require(!input.key(7, 0x81, 2, true, false), "keyboard Volume Down cannot bypass Volume policy");
    require(!input.key(7, 4, 1, false, true), "device-button grant cannot type");
    require(!input.key(7, 4, 0, true, false), "unowned key release rejected");
    require(input.key(7, 4, 1, true, false), "owned key press tracked");
    int touches = 0, keys = 0;
    input.release([&](int p, int f, double x, double y) {
        require(p == 2 && f == 0 && x == .3 && y == .4, "release uses last owned coordinate"); ++touches;
    }, [&](int p, int u, int d) { require(p == 7 && u == 4 && d == 0, "release only owned keys"); ++keys; });
    require(touches == 1 && keys == 1 && input.contacts.empty() && input.keys.empty(), "retirement releases held state");
    require(!input.touch(0, 0, .5, .5) && !input.key(7, 4, 1, true, true), "retired input cannot resume");
    input.release([&](int,int,double,double) { ++touches; }, [&](int,int,int) { ++keys; });
    require(touches == 1 && keys == 1, "retirement is idempotent");
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
