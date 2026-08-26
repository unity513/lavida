# LAVIDA Native Android Push

The web app and Supabase backend support native Android push as a second delivery
channel beside Web Push. The Android app source is not present in this
repository, so the installed app must integrate Firebase Cloud Messaging in its
native wrapper and pass tokens into the existing web layer.

## Native Wrapper Contract

After Supabase login succeeds inside the installed Android app, obtain the FCM
token and register it with one of these web-layer calls:

```js
window.LavidaNotifications.registerAndroidPushToken({
  token: fcmToken,
  platform: "android",
  installationId: stableInstallationId,
  deviceLabel: "Android app",
  appVersion: appVersionName
});
```

or dispatch:

```js
window.dispatchEvent(new CustomEvent("lavida-native-push-token", {
  detail: {
    token: fcmToken,
    platform: "android",
    installationId: stableInstallationId,
    deviceLabel: "Android app",
    appVersion: appVersionName
  }
}));
```

On logout, deactivate only the current app installation:

```js
window.LavidaNotifications.deactivateAndroidPushToken({
  token: fcmToken,
  installationId: stableInstallationId
});
```

## Android Notification Channels

Use these channel IDs to match the backend router:

- `orders_payments`
- `marketplace`
- `projects_printing`
- `games_events`
- `lavida_updates`

Use the native small notification icon resource name `ic_stat_lavida`. This
repository includes the Android-compatible vector at
`assets/android/drawable/ic_stat_lavida.xml`: a transparent monochrome white
`L` mark for Android status-bar notifications. Copy that file into the native
app's `res/drawable` folder.

## Backend Secrets

The Supabase Edge Function needs these secrets for Android delivery:

- `FIREBASE_SERVICE_ACCOUNT_JSON`
- `FIREBASE_PROJECT_ID` when it cannot be inferred from the service account JSON

Do not place Firebase server credentials in frontend JavaScript or in the APK.

## Duplicate Delivery

The backend avoids Web Push delivery when an active native token and a Web Push
subscription share the same `installation_id`. If the native wrapper cannot pass
a stable installation ID that also matches the web layer, LAVIDA will still send
both channels because unreliable device fingerprinting is intentionally avoided.
