#include "net/WebRTCPermissions.h"
#include "net/GuestInputState.h"
#include "protocol/GuestPermissions.generated.h"
#include <algorithm>
#include <iterator>

namespace rctl {

bool guestWebRTCPermissions(const std::vector<std::string> &permissions, WebRTCPermissions &result) {
    result = WebRTCPermissions{};
    result.scoped = true;
    result.guest = true;
    if (permissions.empty() || permissions.size() > std::size(guestPermissionIDs)) return false;
    for (const auto &permission : permissions) {
        if (std::find(std::begin(guestPermissionIDs), std::end(guestPermissionIDs), permission) == std::end(guestPermissionIDs)) return false;
        if (permission == "screen.view") result.screenView = true;
        else if (permission == "input.touch") result.inputTouch = true;
        else if (permission == "input.keyboard") result.inputKeyboard = true;
        else if (permission == "input.button.home") result.buttonMask |= GuestInputState::homeButton;
        else if (permission == "input.button.lock") result.buttonMask |= GuestInputState::lockButton;
        else if (permission == "input.button.volume") result.buttonMask |= GuestInputState::volumeButtons;
        else if (permission == "input.button.system_ui") result.buttonMask |= GuestInputState::systemButtons;
    }
    result.inputButtons = result.buttonMask != 0;
    return result.screenView;
}

WebRTCPermissions legacyWebRTCPermissions() {
    WebRTCPermissions result;
    result.screenView = true;
    result.camera = true;
    result.audioListen = true;
    result.deviceControl = true;
    result.filesRead = true;
    result.filesWrite = true;
    result.microphoneTalk = true;
    return result;
}

WebRTCPermissions scopedWebRTCPermissions(const std::vector<std::string> &scopes) {
    WebRTCPermissions result;
    result.scoped = true;
    for (const auto &scope : scopes) {
        if (scope == "screen.view") result.screenView = true;
        else if (scope == "camera") result.camera = true;
        else if (scope == "audio.listen") result.audioListen = true;
        else if (scope == "device.control") result.deviceControl = true;
        else if (scope == "files.read") result.filesRead = true;
        else if (scope == "files.write") result.filesWrite = true;
        else if (scope == "microphone.talk") result.microphoneTalk = true;
    }
    return result;
}

bool webRTCFilesMessageAllowed(const WebRTCPermissions &permissions,
                               bool binary,
                               std::string_view operation) {
    if (binary) return permissions.filesWrite;
    if (operation == "get") return permissions.filesRead;
    if (operation == "put" || operation == "put_eof") return permissions.filesWrite;
    if (operation == "cancel") return permissions.filesRead || permissions.filesWrite;
    return false;
}

} // namespace rctl
