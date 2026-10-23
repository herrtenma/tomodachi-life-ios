#include <stdlib.h>
#include <string.h>

#include "ipc.h"

extern const ServiceDef svc_sm, svc_lm, svc_appletoe, svc_apm, svc_pctl, svc_aoc, svc_ectx,
    svc_set, svc_setsys, svc_prepo, svc_nifm, svc_time, svc_fs, svc_nvdrv, svc_vi, svc_acc, svc_hid, svc_mii, svc_audren, svc_pl, svc_ngc, svc_ldn;

void nx_services_init(void) {
    const ServiceDef *all[] = {&svc_sm, &svc_lm, &svc_appletoe, &svc_apm, &svc_pctl, &svc_aoc,
                               &svc_ectx, &svc_set, &svc_setsys, &svc_prepo, &svc_nifm, &svc_time, &svc_fs, &svc_nvdrv, &svc_vi, &svc_acc, &svc_hid, &svc_mii, &svc_audren, &svc_pl, &svc_ngc};
    for (unsigned i = 0; i < sizeof all / sizeof *all; i++) nx_service_register(all[i]);
    const char *ldn = getenv("NXRT_LDN");                 // NXRT_LDN=0: no ldn:u (the old stub session)
    if (!ldn || strcmp(ldn, "0")) nx_service_register(&svc_ldn);
    // same interface behind several port names
    nx_service_alias("pctl:s", &svc_pctl);
    nx_service_alias("pctl:r", &svc_pctl);
    nx_service_alias("pctl:a", &svc_pctl);
    nx_service_alias("aoc:u2", &svc_aoc);
    nx_service_alias("prepo:a", &svc_prepo);
    nx_service_alias("prepo:a2", &svc_prepo);
    nx_service_alias("nifm:a", &svc_nifm);
    nx_service_alias("nifm:s", &svc_nifm);
    nx_service_alias("acc:u1", &svc_acc);
    nx_service_alias("mii:u", &svc_mii);
    nx_service_alias("vi:s", &svc_vi);
    nx_service_alias("vi:m", &svc_vi);
    nx_service_alias("nvdrv:a", &svc_nvdrv);
    nx_service_alias("nvdrv:s", &svc_nvdrv);
    nx_service_alias("nvdrv:t", &svc_nvdrv);
    nx_service_alias("time:a", &svc_time);
    nx_service_alias("time:s", &svc_time);
    nx_service_alias("time:r", &svc_time);
}
