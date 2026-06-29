// 최상위 빌드 파일 — 하위 모듈 공통 설정을 여기에 둘 수 있습니다.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
