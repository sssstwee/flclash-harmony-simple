# Xiaomao AI Proxy

Xiaomao AI Proxy（小猫AI代理）is a proxy client for HarmonyOS.

Download the HAP from [Releases](https://github.com/sssstwee/xiaomao-ai-proxy/releases). If unsigned, sign it with a HarmonyOS debug certificate and profile containing your phone’s UDID, then install it using DevEco Studio with developer mode and USB debugging enabled on your HarmonyOS phone.

HarmonyOS checks GitHub Releases on launch, app resume, and after VPN connects. Newer build numbers under the same version also trigger the download prompt. Versions through `0.8.94+2026101502` disabled automatic checks, so install `0.8.94+2026101503` or later manually once to enable future prompts.

Routing, proxy group order, failover and DNS are managed by the [hosted configuration](backend/README.md). Future routing changes normally require only a cloud configuration update.
