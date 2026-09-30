// Thin wrappers over the Linux usbfs ioctls (<linux/usbdevice_fs.h>) and the
// netlink socket address, for Swift, which cannot call variadic ioctl(2) or
// see the ioctl request macros. Compiles to nothing on other platforms.
#ifndef CUSBFS_H
#define CUSBFS_H

#ifdef __linux__

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/usbdevice_fs.h>

// Each wrapper returns the ioctl's result: >= 0 on success, -1 with errno set.

static inline int cusbfs_get_capabilities(int fd, uint32_t *caps) {
    return ioctl(fd, USBDEVFS_GET_CAPABILITIES, caps);
}

static inline int cusbfs_claim_interface(int fd, unsigned int interface) {
    return ioctl(fd, USBDEVFS_CLAIMINTERFACE, &interface);
}

static inline int cusbfs_release_interface(int fd, unsigned int interface) {
    return ioctl(fd, USBDEVFS_RELEASEINTERFACE, &interface);
}

/// Name of the kernel driver bound to the interface ("usbfs" when a process
/// claimed it). Fails with ENODATA when nothing is bound.
static inline int cusbfs_get_driver(int fd, unsigned int interface, char *name, size_t capacity) {
    struct usbdevfs_getdriver request;
    memset(&request, 0, sizeof request);
    request.interface = interface;
    int result = ioctl(fd, USBDEVFS_GETDRIVER, &request);
    if (result >= 0 && capacity > 0) {
        strncpy(name, request.driver, capacity - 1);
        name[capacity - 1] = 0;
    }
    return result;
}

/// Detaches a bound kernel driver and claims the interface in one step, but
/// never when the bound driver is "usbfs" (another process's claim).
static inline int cusbfs_disconnect_claim_except_usbfs(int fd, unsigned int interface) {
    struct usbdevfs_disconnect_claim request;
    memset(&request, 0, sizeof request);
    request.interface = interface;
    request.flags = USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER;
    strcpy(request.driver, "usbfs");
    return ioctl(fd, USBDEVFS_DISCONNECT_CLAIM, &request);
}

static inline int cusbfs_clear_halt(int fd, unsigned int endpoint) {
    return ioctl(fd, USBDEVFS_CLEAR_HALT, &endpoint);
}

/// A synchronous control transfer; returns the bytes transferred.
static inline int cusbfs_control(int fd, uint8_t request_type, uint8_t request, uint16_t value,
                                 uint16_t index, uint16_t length, void *data, uint32_t timeout_ms) {
    struct usbdevfs_ctrltransfer transfer;
    memset(&transfer, 0, sizeof transfer);
    transfer.bRequestType = request_type;
    transfer.bRequest = request;
    transfer.wValue = value;
    transfer.wIndex = index;
    transfer.wLength = length;
    transfer.timeout = timeout_ms;
    transfer.data = data;
    return ioctl(fd, USBDEVFS_CONTROL, &transfer);
}

enum {
    CUSBFS_URB_TYPE_INTERRUPT = USBDEVFS_URB_TYPE_INTERRUPT,
    CUSBFS_URB_TYPE_BULK = USBDEVFS_URB_TYPE_BULK,
    CUSBFS_URB_BULK_CONTINUATION = USBDEVFS_URB_BULK_CONTINUATION,
    CUSBFS_URB_SHORT_NOT_OK = USBDEVFS_URB_SHORT_NOT_OK,
    CUSBFS_CAP_ZERO_PACKET = USBDEVFS_CAP_ZERO_PACKET,
    CUSBFS_CAP_BULK_CONTINUATION = USBDEVFS_CAP_BULK_CONTINUATION,
    CUSBFS_CAP_BULK_SCATTER_GATHER = USBDEVFS_CAP_BULK_SCATTER_GATHER,
    CUSBFS_CAP_NO_PACKET_SIZE_LIM = USBDEVFS_CAP_NO_PACKET_SIZE_LIM,
};

/// A zeroed URB on the heap. The kernel writes the result into it when it is
/// reaped, so it must stay allocated until then (release with `free`).
static inline struct usbdevfs_urb *cusbfs_urb_new(void) {
    return (struct usbdevfs_urb *)calloc(1, sizeof(struct usbdevfs_urb));
}

/// Fills `urb` and submits it. `buffer` must stay valid until the URB is reaped.
static inline int cusbfs_submit_urb(int fd, struct usbdevfs_urb *urb, uint8_t type, uint8_t endpoint,
                                    void *buffer, int length, unsigned int flags) {
    memset(urb, 0, sizeof *urb);
    urb->type = type;
    urb->endpoint = endpoint;
    urb->flags = flags;
    urb->buffer = buffer;
    urb->buffer_length = length;
    urb->usercontext = urb;
    return ioctl(fd, USBDEVFS_SUBMITURB, urb);
}

/// Cancels a submitted URB; it still has to be reaped. EINVAL: already completed.
static inline int cusbfs_discard_urb(int fd, struct usbdevfs_urb *urb) {
    return ioctl(fd, USBDEVFS_DISCARDURB, urb);
}

/// Reaps one completed URB without blocking (EAGAIN when none is ready).
static inline int cusbfs_reap_urb_nodelay(int fd, struct usbdevfs_urb **urb) {
    *urb = NULL;
    return ioctl(fd, USBDEVFS_REAPURBNDELAY, (void *)urb);
}

static inline int cusbfs_urb_status(const struct usbdevfs_urb *urb) { return urb->status; }
static inline int cusbfs_urb_actual_length(const struct usbdevfs_urb *urb) { return urb->actual_length; }

/// Binds a netlink socket to multicast `groups` (sockaddr_nl has padding
/// Swift would otherwise have to spell out).
static inline int cusbfs_netlink_bind(int fd, uint32_t groups) {
    struct sockaddr_nl address;
    memset(&address, 0, sizeof address);
    address.nl_family = AF_NETLINK;
    address.nl_groups = groups;
    return bind(fd, (struct sockaddr *)&address, sizeof address);
}

#endif /* __linux__ */
#endif /* CUSBFS_H */
