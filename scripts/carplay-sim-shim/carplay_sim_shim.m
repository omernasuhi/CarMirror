// iOS 26.4 / 26.5 simülatöründeki CarPlay hatasına geçici yama.
//
// Bu simülatör sürümlerinde CarPlaySupport.framework içindeki
// CPSTemplateInstance sınıfı, CPSDestinationSharingDelegate protokolünün
// iki yöntemini içermiyor. CarPlayTemplateUIHost, harita şablonu
// (CPMapTemplate) her gösterildiğinde bu yöntemleri çağırıp çöküyor.
// Gerçek cihazlarda yöntemler mevcut; sorun yalnızca simülatörde.
//
// Bu kütüphane DYLD_INSERT_LIBRARIES ile simülatördeki süreçlere yüklenir ve
// sınıf varsa eksik yöntemleri ekler; diğer süreçlerde hiçbir şey yapmaz.
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

static BOOL CarMirrorVehicleSupportsDestinationSharing(id self, SEL _cmd) {
    return NO;
}

static void CarMirrorHandleSharedDestination(id self, SEL _cmd, id destination, id completion) {
    NSLog(@"carmirror-carplay-shim: handleSharedDestination:completion: yok sayıldı");
}

static BOOL CarMirrorAddMethodIfMissing(Class cls, const char *name, IMP implementation, const char *types) {
    SEL selector = sel_registerName(name);
    if (class_getInstanceMethod(cls, selector) != NULL) {
        return NO;
    }
    return class_addMethod(cls, selector, implementation, types);
}

static void CarMirrorPatchIfPossible(void) {
    static BOOL patched = NO;
    if (patched) {
        return;
    }
    Class cls = objc_getClass("CPSTemplateInstance");
    if (cls == Nil) {
        return;
    }
    patched = YES;
    int added = 0;
    added += CarMirrorAddMethodIfMissing(cls, "vehicleSupportsDestinationSharing",
                                         (IMP)CarMirrorVehicleSupportsDestinationSharing, "B@:");
    added += CarMirrorAddMethodIfMissing(cls, "handleSharedDestination:completion:",
                                         (IMP)CarMirrorHandleSharedDestination, "v@:@@?");
    NSLog(@"carmirror-carplay-shim: CPSTemplateInstance yamalandı, %d yöntem eklendi", added);
}

static void CarMirrorImageAdded(const struct mach_header *header, intptr_t slide) {
    CarMirrorPatchIfPossible();
}

__attribute__((constructor))
static void CarMirrorInstallCarPlayShim(void) {
    CarMirrorPatchIfPossible();
    // CarPlaySupport henüz yüklenmemişse yüklendiğinde yeniden dene.
    _dyld_register_func_for_add_image(CarMirrorImageAdded);
}
