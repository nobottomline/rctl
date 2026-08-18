#pragma once

#import <Foundation/Foundation.h>

typedef void (*rctl_camera_tcc_callback)(BOOL active);

void rctl_camera_agent_initialize(rctl_camera_tcc_callback tcc_callback);
void rctl_camera_agent_sync(void);
