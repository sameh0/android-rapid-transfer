// C helpers for the parts of GLib/GTK/libadwaita that Swift cannot import:
// function-like macros (type ids, type checks, g_signal_connect), variadic
// functions (g_object_new, g_object_get/set) and GValue handling.
// Keep this file small: everything else is called directly from Swift.
#pragma once

#include <gtk/gtk.h>
#include <adwaita.h>
#include <glib-unix.h>
#include <sys/syscall.h>
#include <unistd.h>

/// Whether the caller runs on the process's main thread.
static inline gboolean art_is_main_thread(void) { return getpid() == (pid_t)syscall(SYS_gettid); }

// MARK: - Type ids (macros in C)

static inline GType art_type_object(void) { return G_TYPE_OBJECT; }
static inline GType art_type_string(void) { return G_TYPE_STRING; }
static inline GType art_type_boolean(void) { return G_TYPE_BOOLEAN; }
static inline GType art_type_file_list(void) { return GDK_TYPE_FILE_LIST; }
static inline gboolean art_value_holds(const GValue *value, GType type) { return G_VALUE_HOLDS(value, type); }

// MARK: - Objects

/// A plain GObject: the item type of our list models (the Swift payload hangs
/// off it as qdata).
static inline GObject *art_plain_object_new(void) { return (GObject *)g_object_new(G_TYPE_OBJECT, NULL); }

static inline guint art_object_refcount(gpointer object) {
    return (guint)g_atomic_int_get((gint *)&((GObject *)object)->ref_count);
}

static inline void art_object_set_bool(gpointer object, const char *name, gboolean value) {
    g_object_set(object, name, value, NULL);
}
static inline void art_object_set_int(gpointer object, const char *name, gint value) {
    g_object_set(object, name, value, NULL);
}
static inline void art_object_set_double(gpointer object, const char *name, gdouble value) {
    g_object_set(object, name, value, NULL);
}
static inline void art_object_set_string(gpointer object, const char *name, const char *value) {
    g_object_set(object, name, value, NULL);
}
static inline gboolean art_object_get_bool(gpointer object, const char *name) {
    gboolean value = FALSE;
    g_object_get(object, name, &value, NULL);
    return value;
}
static inline gint art_object_get_int(gpointer object, const char *name) {
    gint value = 0;
    g_object_get(object, name, &value, NULL);
    return value;
}
static inline gboolean art_object_has_property(gpointer object, const char *name) {
    return g_object_class_find_property(G_OBJECT_GET_CLASS(object), name) != NULL;
}

// MARK: - Signals

/// g_signal_connect_data; a function because GCallback needs a cast Swift
/// cannot write directly. `swapped` passes the user data as the FIRST
/// argument, which lets one callback shape serve signals of any arity.
static inline gulong art_signal_connect(gpointer instance, const char *signal, gconstpointer callback,
                                        gpointer data, GClosureNotify destroy, gboolean swapped) {
    return g_signal_connect_data(instance, signal, G_CALLBACK(callback), data, destroy,
                                 swapped ? G_CONNECT_SWAPPED : (GConnectFlags)0);
}

/// Emits a signal that takes no arguments and returns nothing.
static inline void art_signal_emit_simple(gpointer instance, const char *signal) {
    g_signal_emit_by_name(instance, signal);
}

// MARK: - Content providers

/// A content provider offering `files` as a GdkFileList (GTK serialises it to
/// text/uri-list and the portal formats for the receiving side).
static inline GdkContentProvider *art_content_provider_for_files(GFile **files, gsize count) {
    GdkFileList *list = gdk_file_list_new_from_array(files, count);
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, list);
    GdkContentProvider *provider = gdk_content_provider_new_for_value(&value);
    g_value_unset(&value);
    return provider;
}

// MARK: - Main-queue bridge
//
// libdispatch exports these for CoreFoundation's run loop; they are in no
// public header on Linux. The handle is an eventfd that becomes readable when
// work is enqueued on the main queue; the callback drains the main queue and
// must run on the main thread.

extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);
