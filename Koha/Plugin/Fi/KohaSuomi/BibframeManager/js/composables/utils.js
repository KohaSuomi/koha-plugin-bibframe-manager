// Utility composables for Bibframe Manager
export function useEntityHelpers() {
    const getEntityIcon = (type) => {
        const icons = {
            work: 'fas fa-book',
            expression: 'fas fa-file-alt',
            manifestation: 'fas fa-box',
            item: 'fas fa-barcode'
        };
        return icons[type] || 'fas fa-question';
    };
    
    const getEntityBadgeClass = (type) => {
        const classes = {
            work: 'primary',
            expression: 'success',
            manifestation: 'warning',
            item: 'danger'
        };
        return classes[type] || 'secondary';
    };
    
    const getEntityDescription = (type) => {
        const descriptions = {
            work: 'Abstract intellectual or artistic creation',
            expression: 'Specific realization of a work',
            manifestation: 'Physical embodiment of an expression',
            item: 'Single example of a manifestation'
        };
        return descriptions[type] || '';
    };
    
    return {
        getEntityIcon,
        getEntityBadgeClass,
        getEntityDescription
    };
}

export function useFileOperations() {
    const downloadOutput = (content, recordId, format) => {
        const blob = new Blob([content], { type: 'text/plain' });
        const url = window.URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        
        const extensions = {
            'turtle': 'ttl',
            'json-ld': 'jsonld',
            'ntriples': 'nt',
            'rdf-xml': 'rdf'
        };
        
        a.download = `bffi_${recordId}.${extensions[format] || 'txt'}`;
        a.click();
        window.URL.revokeObjectURL(url);
    };
    
    const copyToClipboard = (text) => {
        const textarea = document.createElement('textarea');
        textarea.value = text;
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        
        return true;
    };
    
    return {
        downloadOutput,
        copyToClipboard
    };
}
