// Carriacou Connect config. Placeholder values = the site runs in SAMPLE mode (reads products.json).
// Fill in your Supabase project URL and anon (public) key to turn on accounts and live data.
// See README.txt. NEVER put a service_role / secret key here: this file is public.
window.CCONNECT_CONFIG = {
  SUPABASE_URL: "https://zokmoxnzmyfxcpsrggaz.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_5a5Pq7cycqYrH-Sp0O6t8g_QSF4vqR2",
  // v1.20 card payments: "mock" = TEST gateway (no real money, test card numbers only). "off" = no card checkout.
  // Must match platform_flags.payments_mode on the server (payments_mock.sql). Never "mock" once real payments are live.
  PAYMENTS_MODE: "mock"
};
