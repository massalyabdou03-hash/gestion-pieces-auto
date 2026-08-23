// =============================================================================
// A CONFIGURER : colle ici l'URL et la clé "anon public" de ton projet Supabase
// (Supabase Dashboard > Project Settings > API)
// =============================================================================
const SUPABASE_URL = "https://firytchonwlvthschvow.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_Idtn_tErn8sJxXNC3WEAkA_9vGfT31L";

// Adresse e‑mail de l'administrateur utilisée par la connexion par mot de passe
// Remplace par l'adresse admin réelle de ton projet Supabase
const ADMIN_EMAIL = "1203@acces.local";
const RECOUVRA_URL = "https://melodic-kangaroo-4b0586.netlify.app/";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
