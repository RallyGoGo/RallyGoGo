import { useState, useEffect, useCallback } from 'react';
import { Session } from '@supabase/supabase-js';
import { supabase, Profile } from '../lib/supabase';
import { logger } from '../utils/logger';

export function useRallyData() {
    const [session, setSession] = useState<Session | null>(null);
    const [profile, setProfile] = useState<Profile | null>(null);
    const [activeNotice, setActiveNotice] = useState<string | null>(null);
    // Using any[] because we enrich Match rows with p1_name..p4_name at fetch time
    // Downstream components cast to AppMatch as needed
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const [matches, setMatches] = useState<any[]>([]);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const [queue, setQueue] = useState<any[]>([]);
    const [isInitializing, setIsInitializing] = useState(true);

    const cleanupExpiredQueue = useCallback(async () => {
        try {
            const { data, error } = await supabase.rpc('remove_expired_from_queue');
            if (error) {
                logger.warn('queue.cleanup_fail', { message: error.message });
                return { deleted: 0, repaired: 0 };
            }

            const payload = (data ?? {}) as {
                deleted_count?: number;
                repaired_count?: number;
                success?: boolean;
            };

            if (payload.success === false) {
                return { deleted: 0, repaired: 0 };
            }

            return {
                deleted: Number(payload.deleted_count ?? 0),
                repaired: Number(payload.repaired_count ?? 0)
            };
        } catch (err) {
            logger.warn('queue.cleanup_exception', err);
            return { deleted: 0, repaired: 0 };
        }
    }, []);

    // ============================================================================
    // DATA FETCHING FUNCTIONS
    // ============================================================================
    const fetchProfile = useCallback(async (userId: string) => {
        try {
            const { data, error } = await supabase
                .from('profiles')
                .select('*')
                .eq('id', userId)
                .maybeSingle();

            if (error) {
                logger.error('profile.fetch_fail', error.message);
                return null;
            }

            if (data) {
                setProfile(data);
            }
            return data;
        } catch (err) {
            logger.error('profile.fetch_exception', err);
            return null;
        }
    }, []);

    const fetchNotice = useCallback(async () => {
        try {
            const { data, error } = await supabase
                .from('notices')
                .select('content')
                .eq('is_active', true)
                .order('created_at', { ascending: false })
                .limit(1)
                .maybeSingle();

            if (error) {
                logger.error('notice.fetch_fail', error.message);
                return null;
            }

            setActiveNotice(data?.content ?? null);
            return data;
        } catch (err) {
            logger.error('notice.fetch_exception', err);
            return null;
        }
    }, []);

    const fetchMatches = useCallback(async () => {
        try {
            const { data, error } = await supabase
                .from('matches')
                .select('*')
                .in('status', ['DRAFT', 'PLAYING', 'SCORING', 'PENDING'])
                .order('created_at', { ascending: false });

            if (error) {
                logger.error('match.fetch_fail', error.message);
                return [];
            }

            if (data) {
                // Enrich with profiles (Manual Join for performance/type simplicity)
                const allPlayerIds = new Set<string>();
                data.forEach((m) => {
                    if (m.player_1) allPlayerIds.add(m.player_1);
                    if (m.player_2) allPlayerIds.add(m.player_2);
                    if (m.player_3) allPlayerIds.add(m.player_3);
                    if (m.player_4) allPlayerIds.add(m.player_4);
                });

                let profileMap = new Map<string, string>();
                if (allPlayerIds.size > 0) {
                    const { data: profiles } = await supabase
                        .from('profiles')
                        .select('id, name')
                        .in('id', Array.from(allPlayerIds));

                    if (profiles) {
                        profileMap = new Map(profiles.map(p => [p.id, p.name]));
                    }
                }

                const enriched = data.map(m => ({
                    ...m,
                    p1_name: (m.player_1 ? profileMap.get(m.player_1) : '') || 'Unknown',
                    p2_name: (m.player_2 ? profileMap.get(m.player_2) : '') || 'Unknown',
                    p3_name: (m.player_3 ? profileMap.get(m.player_3) : '') || 'Unknown',
                    p4_name: (m.player_4 ? profileMap.get(m.player_4) : '') || 'Unknown',
                }));

                // We cast to any here because we are extending the type at runtime. 
                // In a real scenario, we should define an EnrichedMatch type.
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                setMatches(enriched as any);
                return enriched;
            }
            return [];
        } catch (err) {
            logger.error('match.fetch_exception', err);
            return [];
        }
    }, []);

    const fetchQueue = useCallback(async () => {
        try {
            // Keep queue expiry and missing departure_time handling on server time.
            await cleanupExpiredQueue();

            const { data, error } = await supabase
                .from('queue')
                .select(`
                    *,
                    profiles (name, ntrp, gender, games_played_today, elo_mens_doubles, elo_womens_doubles, is_guest, elo_mixed_doubles, elo_singles)
                `)
                .eq('is_active', true)
                .order('priority_score', { ascending: false });

            if (error) {
                logger.error('queue.fetch_fail', error.message);
                return [];
            }

            if (data) {
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                setQueue(data as any);
                return data;
            }
            return [];
        } catch (err) {
            logger.error('queue.fetch_exception', err);
            return [];
        }
    }, [cleanupExpiredQueue]);

    const checkDailyReset = useCallback(async () => {
        try {
            const { data, error } = await supabase.rpc('check_and_reset_daily');
            if (error) {
                // If RPC missing (during migration), ignore
                // logger.warn('system.daily_reset_check_fail', error.message);
                return;
            }
            if (data === true) {
                logger.info('system.daily_reset_triggered', { message: '22:00 Reset executed.' });
                // Refresh data
                void fetchQueue();
                void fetchMatches();
                if (session?.user?.id) void fetchProfile(session.user.id);
            }
        } catch (err) {
            logger.error('system.daily_reset_exception', err);
        }
    }, [fetchQueue, fetchMatches, fetchProfile, session]);

    // ============================================================================
    // AUTH & REALTIME SUBSCRIPTION
    // ============================================================================
    useEffect(() => {
        let mounted = true;

        // Auth Listener
        const { data: { subscription: authSubscription } } = supabase.auth.onAuthStateChange(
            async (_event, newSession) => {
                if (!mounted) return;

                setSession(newSession);

                if (newSession?.user?.id) {
                    // Fetch profile immediately if session exists
                    void fetchProfile(newSession.user.id);
                } else {
                    setProfile(null);
                }

                // End initialization once we know auth state
                setIsInitializing(false);
            }
        );

        // Failsafe Timeout
        const failsafeTimeout = setTimeout(() => {
            if (mounted && isInitializing) {
                logger.warn('app.init_timeout', { message: 'Forcing initialization fix' });
                setIsInitializing(false);
            }
        }, 5000);

        // Realtime Subscription
        const realtimeChannel = supabase
            .channel('app-realtime')
            .on('postgres_changes', { event: '*', schema: 'public', table: 'notices' }, () => void fetchNotice())
            .on('postgres_changes', { event: '*', schema: 'public', table: 'matches' }, () => {
                void fetchMatches();
                void fetchQueue();
            })
            .on('postgres_changes', { event: '*', schema: 'public', table: 'queue' }, () => void fetchQueue())
            .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'profiles' }, async (payload) => {
                const { data: { user } } = await supabase.auth.getUser();
                if (payload.new && user?.id === (payload.new as Profile).id) {
                    setProfile(payload.new as Profile);
                }
            })
            .subscribe((status) => {
                if (status !== 'SUBSCRIBED') {
                    // logger.debug('realtime.status', status);
                }
            });

        // Broadcast-based match sync channel (fallback/complement to postgres changes).
        const matchSyncChannel = supabase
            .channel('match-sync', { config: { broadcast: { self: true } } })
            .on('broadcast', { event: 'match_state_changed' }, () => {
                void fetchMatches();
                void fetchQueue();
            })
            .subscribe();

        // Initial Fetch
        void fetchNotice();
        void fetchMatches();
        void fetchQueue();
        void checkDailyReset();

        // Safety polling so expired users disappear even without realtime DB changes.
        const queueMaintenanceInterval = setInterval(() => {
            void (async () => {
                const result = await cleanupExpiredQueue();
                if (result.deleted > 0 || result.repaired > 0) {
                    void fetchQueue();
                }
            })();
        }, 30000);

        // Realtime fallback polling to recover from temporary websocket drops.
        const liveSyncInterval = setInterval(() => {
            void fetchMatches();
        }, 10000);

        return () => {
            mounted = false;
            clearTimeout(failsafeTimeout);
            clearInterval(queueMaintenanceInterval);
            clearInterval(liveSyncInterval);
            authSubscription.unsubscribe();
            if (realtimeChannel) supabase.removeChannel(realtimeChannel);
            if (matchSyncChannel) supabase.removeChannel(matchSyncChannel);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [cleanupExpiredQueue, fetchMatches, fetchNotice, fetchProfile, fetchQueue]); // checkDailyReset excluded to avoid loop if session changes often

    return {
        session,
        profile,
        activeNotice,
        matches,
        queue,
        isInitializing,
        refetch: {
            profile: fetchProfile,
            matches: fetchMatches,
            queue: fetchQueue,
            notice: fetchNotice
        }
    };
}
