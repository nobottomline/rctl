#pragma once

#include <string_view>
#include <vector>
#include <string>

namespace rctl {

struct WebRTCPermissions {
    bool scoped = false;
    bool screenView = false;
    bool camera = false;
    bool audioListen = false;
    bool deviceControl = false;
    bool filesRead = false;
    bool filesWrite = false;
    bool microphoneTalk = false;
};

WebRTCPermissions legacyWebRTCPermissions();
WebRTCPermissions scopedWebRTCPermissions(const std::vector<std::string> &scopes);
bool webRTCFilesMessageAllowed(const WebRTCPermissions &permissions,
                               bool binary,
                               std::string_view operation);

} // namespace rctl
