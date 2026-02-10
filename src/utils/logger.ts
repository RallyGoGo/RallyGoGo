export type LogEvent = {
    event: string;
    [key: string]: unknown;
};

/**
 * Zero Script QA Logger
 * Outputs structured JSON logs for pattern-based verification.
 */
export const logger = {
    info: (event: string, data?: object) => {
        if (import.meta.env.DEV) {
            console.log(JSON.stringify({ level: 'INFO', event, timestamp: new Date().toISOString(), ...data }));
        }
    },
    error: (event: string, error: unknown, data?: object) => {
        console.error(JSON.stringify({
            level: 'ERROR',
            event,
            timestamp: new Date().toISOString(),
            error: error instanceof Error ? error.message : String(error),
            ...data
        }));
    },
    warn: (event: string, data?: object) => {
        console.warn(JSON.stringify({ level: 'WARN', event, timestamp: new Date().toISOString(), ...data }));
    },
};
