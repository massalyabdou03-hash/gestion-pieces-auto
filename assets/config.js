// =============================================================================
// A CONFIGURER : colle ici l'URL et la clé "anon public" de ton projet Supabase
// (Supabase Dashboard > Project Settings > API)
// =============================================================================
const SUPABASE_URL = "https://firytchonwlvthschvow.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_Idtn_tErn8sJxXNC3WEAkA_9vGfT31L";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
