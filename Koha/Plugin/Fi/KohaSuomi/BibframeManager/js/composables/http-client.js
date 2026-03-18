// API Composable for HTTP requests
const { ref } = Vue;

export function HTTPClient() {
    const loading = ref(false);
    const error = ref(null);
    
    const baseUrl = '/api/v1';
    
    /**
     * Make HTTP request
     * @param {string} endpoint - API endpoint
     * @param {Object} options - Fetch options
     * @returns {Promise<any>}
     */
    const request = async (endpoint, options = {}) => {
        loading.value = true;
        error.value = null;
        
        try {
            const url = endpoint.startsWith('http') ? endpoint : `${baseUrl}${endpoint}`;
            
            const defaultOptions = {
                headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    ...options.headers
                },
                ...options
            };
            
            const response = await fetch(url, defaultOptions);
            
            if (!response.ok) {
                const errorData = await response.json().catch(() => ({ error: response.statusText }));
                throw new Error(errorData.error || errorData.message || `HTTP ${response.status}: ${response.statusText}`);
            }
            
            // Handle empty responses
            const contentType = response.headers.get('content-type');
            if (!contentType || response.status === 204) {
                return null;
            }
            
            // Parse response based on content type
            if (contentType.includes('application/json') || contentType.includes('application/marc-in-json')) {
                return await response.json();
            } else if (contentType.includes('application/marcxml+xml') || contentType.includes('text/xml')) {
                return await response.text(); // Return XML as string
            } else if (contentType.includes('application/marc')) {
                return await response.blob(); // Return binary MARC
            } else if (contentType.includes('text/plain') || contentType.includes('text/')) {
                return await response.text();
            } else {
                return await response.blob();
            }
            
        } catch (err) {
            error.value = err.message;
            throw err;
        } finally {
            loading.value = false;
        }
    };
    
    /**
     * GET request
     * @param {string} endpoint - API endpoint
     * @param {Object} params - Query parameters
     * @param {string} accept - Accept header MIME type
     * @returns {Promise<any>}
     */
    const get = async (endpoint, params = {}, accept = 'application/json') => {
        const queryString = new URLSearchParams(params).toString();
        const url = queryString ? `${endpoint}?${queryString}` : endpoint;
        
        return request(url, {
            method: 'GET',
            headers: {
                'Accept': accept
            }
        });
    };
    
    /**
     * GET request for MARCXML format
     * @param {string} endpoint - API endpoint
     * @param {Object} params - Query parameters
     * @returns {Promise<string>} XML string
     */
    const getMarcXML = async (endpoint, params = {}) => {
        return get(endpoint, params, 'application/marcxml+xml');
    };
    
    /**
     * GET request for MARC-in-JSON format
     * @param {string} endpoint - API endpoint
     * @param {Object} params - Query parameters
     * @returns {Promise<Object>} JSON object
     */
    const getMarcJSON = async (endpoint, params = {}) => {
        return get(endpoint, params, 'application/marc-in-json');
    };
    
    /**
     * GET request for binary MARC format
     * @param {string} endpoint - API endpoint
     * @param {Object} params - Query parameters
     * @returns {Promise<Blob>} Binary MARC blob
     */
    const getMarcBinary = async (endpoint, params = {}) => {
        return get(endpoint, params, 'application/marc');
    };
    
    /**
     * GET request for plain text
     * @param {string} endpoint - API endpoint
     * @param {Object} params - Query parameters
     * @returns {Promise<string>} Plain text
     */
    const getText = async (endpoint, params = {}) => {
        return get(endpoint, params, 'text/plain');
    };
    
    /**
     * POST request
     * @param {string} endpoint - API endpoint
     * @param {Object} data - Request body
     * @returns {Promise<any>}
     */
    const post = async (endpoint, data = {}) => {
        return request(endpoint, {
            method: 'POST',
            body: JSON.stringify(data)
        });
    };
    
    /**
     * PUT request
     * @param {string} endpoint - API endpoint
     * @param {Object} data - Request body
     * @returns {Promise<any>}
     */
    const put = async (endpoint, data = {}) => {
        return request(endpoint, {
            method: 'PUT',
            body: JSON.stringify(data)
        });
    };
    
    /**
     * PATCH request
     * @param {string} endpoint - API endpoint
     * @param {Object} data - Request body
     * @returns {Promise<any>}
     */
    const patch = async (endpoint, data = {}) => {
        return request(endpoint, {
            method: 'PATCH',
            body: JSON.stringify(data)
        });
    };
    
    /**
     * DELETE request
     * @param {string} endpoint - API endpoint
     * @returns {Promise<any>}
     */
    const del = async (endpoint) => {
        return request(endpoint, {
            method: 'DELETE'
        });
    };
    
    /**
     * Upload file(s)
     * @param {string} endpoint - API endpoint
     * @param {FormData} formData - Form data with files
     * @returns {Promise<any>}
     */
    const upload = async (endpoint, formData) => {
        loading.value = true;
        error.value = null;
        
        try {
            const url = endpoint.startsWith('http') ? endpoint : `${baseUrl}${endpoint}`;
            
            const response = await fetch(url, {
                method: 'POST',
                body: formData
                // Don't set Content-Type header - browser will set it with boundary
            });
            
            if (!response.ok) {
                const errorData = await response.json().catch(() => ({ error: response.statusText }));
                throw new Error(errorData.error || errorData.message || `Upload failed: ${response.statusText}`);
            }
            
            return await response.json();
            
        } catch (err) {
            error.value = err.message;
            throw err;
        } finally {
            loading.value = false;
        }
    };
    
    /**
     * Clear error state
     */
    const clearError = () => {
        error.value = null;
    };
    
    return {
        loading,
        error,
        baseUrl,
        request,
        get,
        getMarcXML,
        getMarcJSON,
        getMarcBinary,
        getText,
        post,
        put,
        patch,
        del,
        delete: del, // alias
        upload,
        clearError
    };
}
