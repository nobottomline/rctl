#include "net/WebRTCPermissions.h"

namespace rctl {

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
