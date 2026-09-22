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
        async convertRecordToBibframe(biblionumber, format = 'turtle', standard = 'bffi') {
            return await httpClient.post(url + '/bibframe/convert', {
                method: 'biblio',
                biblionumber: biblionumber,
                format: format,
                standard: standard
            });
        }
    }
}