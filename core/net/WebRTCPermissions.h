#pragma once

#include <cstdint>
#include <string_view>
#include <vector>
#include <string>

namespace rctl {

struct WebRTCPermissions {
    bool scoped = false;
    bool guest = false;
    bool inputTouch = false;
    bool inputKeyboard = false;
    bool inputText = false;
    bool inputButtons = false;
    uint32_t buttonMask = 0;
    bool screenView = false;
    bool camera = false;
    bool audioListen = false;
    bool roomMicListen = false;
    std::vector<std::string> guestRights;
    bool deviceControl = false;
    bool filesRead = false;
    bool filesWrite = false;
    bool microphoneTalk = false;
};

WebRTCPermissions legacyWebRTCPermissions();
bool guestWebRTCPermissions(const std::vector<std::string> &permissions, WebRTCPermissions &result);
WebRTCPermissions scopedWebRTCPermissions(const std::vector<std::string> &scopes);
bool webRTCFilesMessageAllowed(const WebRTCPermissions &permissions,
                               bool binary,
                               std::string_view operation);

} // namespace rctl
