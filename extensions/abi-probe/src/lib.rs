//! No-op lifecycle probe. No files, network, UI registration or background work.
use core::{ffi::c_void, mem::size_of, ptr};
use pulse_abi::{HostV1, PluginV1, Status, ABI_VERSION, ERROR_ABI, ERROR_ARGUMENT, OK, SDK_PREVIEW};

#[no_mangle]
#[allow(non_snake_case)]
pub extern "C" fn PulsePluginSdkPreview() -> u32 {
    SDK_PREVIEW
}

unsafe extern "C" fn activate(instance: *mut c_void) -> Status {
    if instance.is_null() {
        ERROR_ARGUMENT
    } else {
        OK
    }
}

unsafe extern "C" fn deactivate(_instance: *mut c_void) {}

unsafe extern "C" fn destroy(instance: *mut c_void) {
    if !instance.is_null() {
        // SAFETY: the host calls destroy once for the instance created by entry.
        unsafe { drop(Box::from_raw(instance.cast::<u8>())) };
    }
}

/// Pulse entry point; the host supplies initialized, aligned ABI table headers.
///
/// # Safety
/// Non-null inputs must point to valid headers and, after size validation, to
/// readable HostV1 and writable PluginV1 storage with no conflicting access.
/// The host owns the tables and must destroy each successful instance once.
#[no_mangle]
#[allow(non_snake_case)]
pub unsafe extern "C" fn PulsePluginEntryV1(host: *const HostV1, out: *mut PluginV1) -> Status {
    if host.is_null() || out.is_null() {
        return ERROR_ABI;
    }
    // SAFETY: the caller guarantees readable initialized table headers.
    let (host_size, host_version, out_size, out_version) = unsafe {
        (
            ptr::addr_of!((*host).size).read(),
            ptr::addr_of!((*host).version).read(),
            ptr::addr_of!((*out).size).read(),
            ptr::addr_of!((*out).version).read(),
        )
    };
    if host_size < size_of::<HostV1>() as u32
        || out_size < size_of::<PluginV1>() as u32
        || host_version != ABI_VERSION
        || out_version != ABI_VERSION
    {
        return ERROR_ABI;
    }

    // SAFETY: the caller's writable table has been checked for size and version.
    unsafe {
        out.write(PluginV1 {
            size: size_of::<PluginV1>() as u32,
            version: ABI_VERSION,
            instance: Box::into_raw(Box::new(0_u8)).cast(),
            activate: Some(activate),
            deactivate: Some(deactivate),
            destroy: Some(destroy),
        });
    }
    OK
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host() -> HostV1 {
        HostV1 {
            size: size_of::<HostV1>() as u32,
            version: ABI_VERSION,
            context: ptr::null_mut(),
            query_interface: None,
        }
    }

    fn output() -> PluginV1 {
        PluginV1 {
            size: size_of::<PluginV1>() as u32,
            version: ABI_VERSION,
            instance: ptr::null_mut(),
            activate: None,
            deactivate: None,
            destroy: None,
        }
    }

    #[test]
    fn accepts_matching_abi_and_runs_lifecycle() {
        let host = host();
        let mut out = output();
        // SAFETY: both tables are valid, and the instance is destroyed once.
        unsafe {
            assert_eq!(PulsePluginEntryV1(&host, &mut out), OK);
            assert!(!out.instance.is_null());
            assert_eq!(out.activate.unwrap()(out.instance), OK);
            out.deactivate.unwrap()(out.instance);
            out.destroy.unwrap()(out.instance);
        }
    }

    #[test]
    fn rejects_short_and_incompatible_tables() {
        let mut host = host();
        let mut out = output();
        host.size = 8;
        // SAFETY: valid headers remain accessible even with a declared short size.
        assert_eq!(unsafe { PulsePluginEntryV1(&host, &mut out) }, ERROR_ABI);
        host.size = size_of::<HostV1>() as u32;
        out.version = 99;
        // SAFETY: both tables are valid; the version is deliberately incompatible.
        assert_eq!(unsafe { PulsePluginEntryV1(&host, &mut out) }, ERROR_ABI);
        assert!(out.instance.is_null());
    }

    #[test]
    fn rejects_null_and_reports_preview() {
        // SAFETY: null inputs are explicitly handled before any dereference.
        assert_eq!(unsafe { PulsePluginEntryV1(ptr::null(), ptr::null_mut()) }, ERROR_ABI);
        assert_eq!(PulsePluginSdkPreview(), 3);
    }
}
