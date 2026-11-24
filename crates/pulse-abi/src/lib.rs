//! Minimal ABI probe declarations, transcribed from the pinned public abi.h.
//! Not a complete SDK. Validate against the upstream C header before release.
use core::ffi::{c_char, c_void};

pub const ABI_VERSION: u32 = 1;
pub const SDK_PREVIEW: u32 = 3;
pub type Status = i32;
pub const OK: Status = 0;
pub const ERROR_ARGUMENT: Status = 1;
pub const ERROR_ABI: Status = 2;
pub const ERROR_INITIALIZATION: Status = 4;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct StringView {
    pub data: *const c_char,
    pub length: u32,
}

pub type QueryInterface =
    unsafe extern "C" fn(*mut c_void, StringView, u32, *mut c_void, u32) -> Status;

#[repr(C)]
pub struct HostV1 {
    pub size: u32,
    pub version: u32,
    pub context: *mut c_void,
    pub query_interface: Option<QueryInterface>,
}

#[repr(C)]
pub struct PluginV1 {
    pub size: u32,
    pub version: u32,
    pub instance: *mut c_void,
    pub activate: Option<unsafe extern "C" fn(*mut c_void) -> Status>,
    pub deactivate: Option<unsafe extern "C" fn(*mut c_void)>,
    pub destroy: Option<unsafe extern "C" fn(*mut c_void)>,
}

#[cfg(all(test, target_pointer_width = "64"))]
mod tests {
    use super::*;
    use core::mem::{align_of, offset_of, size_of};

    #[test]
    fn x64_abi_layout() {
        assert_eq!((size_of::<StringView>(), align_of::<StringView>()), (16, 8));
        assert_eq!(offset_of!(StringView, length), 8);
        assert_eq!((size_of::<HostV1>(), align_of::<HostV1>()), (24, 8));
        assert_eq!(offset_of!(HostV1, context), 8);
        assert_eq!(offset_of!(HostV1, query_interface), 16);
        assert_eq!((size_of::<PluginV1>(), align_of::<PluginV1>()), (40, 8));
        assert_eq!(offset_of!(PluginV1, instance), 8);
        assert_eq!(offset_of!(PluginV1, activate), 16);
        assert_eq!(offset_of!(PluginV1, deactivate), 24);
        assert_eq!(offset_of!(PluginV1, destroy), 32);
    }
}
