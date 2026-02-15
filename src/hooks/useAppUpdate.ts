import { useCallback, useEffect, useRef, useState } from 'react';

type VersionPayload = {
    buildId?: string;
};

const CHECK_INTERVAL_MS = 60_000;

const fetchLatestBuildId = async (): Promise<string | null> => {
    try {
        const response = await fetch(`/version.json?t=${Date.now()}`, {
            cache: 'no-store',
        });

        if (!response.ok) return null;

        const payload = (await response.json()) as VersionPayload;
        return typeof payload.buildId === 'string' ? payload.buildId : null;
    } catch {
        return null;
    }
};

export function useAppUpdate() {
    const [latestBuildId, setLatestBuildId] = useState<string | null>(null);
    const [dismissedBuildId, setDismissedBuildId] = useState<string | null>(null);
    const [isUpdateAvailable, setIsUpdateAvailable] = useState(false);
    const lastSeenBuildIdRef = useRef<string | null>(null);

    const checkForUpdate = useCallback(async () => {
        const remoteBuildId = await fetchLatestBuildId();
        if (!remoteBuildId) return;

        if (remoteBuildId === lastSeenBuildIdRef.current) {
            return;
        }

        lastSeenBuildIdRef.current = remoteBuildId;
        setLatestBuildId(remoteBuildId);

        if (remoteBuildId !== __APP_BUILD_ID__ && dismissedBuildId !== remoteBuildId) {
            setIsUpdateAvailable(true);
            return;
        }

        setIsUpdateAvailable(false);
    }, [dismissedBuildId]);

    const applyUpdate = useCallback(() => {
        window.location.replace(`/?refresh=${Date.now()}`);
    }, []);

    const dismissUpdate = useCallback(() => {
        if (latestBuildId) {
            setDismissedBuildId(latestBuildId);
        }
        setIsUpdateAvailable(false);
    }, [latestBuildId]);

    useEffect(() => {
        void checkForUpdate();

        const intervalId = window.setInterval(() => {
            void checkForUpdate();
        }, CHECK_INTERVAL_MS);

        const handleVisibility = () => {
            if (document.visibilityState === 'visible') {
                void checkForUpdate();
            }
        };

        const handlePageShow = () => {
            void checkForUpdate();
        };

        document.addEventListener('visibilitychange', handleVisibility);
        window.addEventListener('pageshow', handlePageShow);
        window.addEventListener('focus', handlePageShow);

        return () => {
            clearInterval(intervalId);
            document.removeEventListener('visibilitychange', handleVisibility);
            window.removeEventListener('pageshow', handlePageShow);
            window.removeEventListener('focus', handlePageShow);
        };
    }, [checkForUpdate]);

    return {
        isUpdateAvailable,
        applyUpdate,
        dismissUpdate,
    };
}
