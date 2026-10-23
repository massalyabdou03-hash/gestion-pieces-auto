// =============================================================================
// Connexion Supabase : URL du projet et clé publique (publishable / anon).
// Cette clé est faite pour être visible dans le navigateur : c'est la sécurité
// de la base (droits et politiques RLS) qui protège les données, pas le secret
// de cette clé. Ne mets JAMAIS ici la clé "service_role".
// =============================================================================
const SUPABASE_URL = "https://firytchonwlvthschvow.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_Idtn_tErn8sJxXNC3WEAkA_9vGfT31L";


const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
