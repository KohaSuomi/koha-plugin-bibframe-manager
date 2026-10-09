import { HTTPClient } from './http-client.js';

export function useKohaApi() {
    const httpClient = HTTPClient();
    
    return {
        // Fetch single record
        async getRecordByBiblionumber(biblionumber) {
            return await httpClient.get(`/biblios/${biblionumber}`);
        },
    };
}

export function usePluginApi() {
    const httpClient = HTTPClient();

    const url = '/contrib/kohasuomi';

    return {
        async convertRecordToBibframe(biblionumber, format = 'turtle', standard = 'bffi', saveToDb = false, baseUri = null) {
            const payload = {
                method: 'biblio',
                biblionumber: biblionumber,
                format: format,
                standard: standard,
                save_to_db: saveToDb
            };
            if (baseUri) payload.base_uri = baseUri;
            return await httpClient.post(url + '/bibframe/convert', payload);
        }
    }
}
